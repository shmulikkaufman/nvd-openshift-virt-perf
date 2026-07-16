#!/bin/bash
# Prerequisites check for GPU Operator VM passthrough on gpu03
# Run on launchpad: bash scripts/prereq-check-gpu-operator.sh

PASS=0
FAIL=0
WARN=0

ok()   { echo "  [PASS] $*"; ((PASS++)); }
fail() { echo "  [FAIL] $*"; ((FAIL++)); }
warn() { echo "  [WARN] $*"; ((WARN++)); }
section() { echo ""; echo "=== $* ==="; }

# -------------------------------------------------------
section "1. GPU Operator Namespace & CRD"
# -------------------------------------------------------
if oc get ns nvidia-gpu-operator &>/dev/null; then
  ok "namespace nvidia-gpu-operator exists"
else
  fail "namespace nvidia-gpu-operator not found — GPU Operator not installed"
fi

if oc get crd clusterpolicies.nvidia.com &>/dev/null; then
  ok "ClusterPolicy CRD exists"
else
  fail "ClusterPolicy CRD missing"
fi

# -------------------------------------------------------
section "2. ClusterPolicy State"
# -------------------------------------------------------
CP_STATE=$(oc get clusterpolicy -A -o jsonpath='{.items[0].status.state}' 2>/dev/null)
CP_NAME=$(oc get clusterpolicy -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$CP_STATE" ]; then
  if [ "$CP_STATE" = "ready" ]; then
    ok "ClusterPolicy '$CP_NAME' state: $CP_STATE"
  else
    fail "ClusterPolicy '$CP_NAME' state: $CP_STATE (expected: ready)"
  fi
  echo "  Full status:"
  oc get clusterpolicy -A -o jsonpath='{.items[0].status}' 2>/dev/null | python3 -m json.tool 2>/dev/null | head -30
else
  fail "No ClusterPolicy found"
fi

# -------------------------------------------------------
section "3. GPU Operator Pods on gpu03"
# -------------------------------------------------------
echo "  Pods scheduled on lp-nvaie-rh-gpu03:"
oc get pods -n nvidia-gpu-operator -o wide 2>/dev/null | grep -E "NAME|gpu03" || warn "No pods found on gpu03"

CRITICAL_PODS=("nvidia-device-plugin" "gpu-feature-discovery" "nvidia-driver-daemonset" "nvidia-container-toolkit")
for POD in "${CRITICAL_PODS[@]}"; do
  COUNT=$(oc get pods -n nvidia-gpu-operator -o wide 2>/dev/null | grep gpu03 | grep -c "$POD" || true)
  if [ "$COUNT" -ge 1 ]; then
    STATE=$(oc get pods -n nvidia-gpu-operator -o wide 2>/dev/null | grep gpu03 | grep "$POD" | awk '{print $3}' | head -1)
    if [ "$STATE" = "Running" ]; then
      ok "$POD: Running"
    else
      fail "$POD: $STATE (not Running)"
    fi
  else
    warn "$POD: not found on gpu03"
  fi
done

# -------------------------------------------------------
section "4. GPU Resources Available on gpu03"
# -------------------------------------------------------
echo "  Allocatable nvidia resources:"
oc get node lp-nvaie-rh-gpu03 -o json 2>/dev/null | python3 -c "
import json, sys
n = json.load(sys.stdin)
cap   = n['status'].get('capacity', {})
alloc = n['status'].get('allocatable', {})
nvidia_cap   = {k: v for k, v in cap.items()   if 'nvidia' in k.lower()}
nvidia_alloc = {k: v for k, v in alloc.items() if 'nvidia' in k.lower()}
if nvidia_alloc:
    for k in sorted(nvidia_alloc):
        print(f'    capacity={cap.get(k,\"?\")}  allocatable={nvidia_alloc[k]}  resource={k}')
else:
    print('    NONE — GPU Operator device plugin may not be running or GPU driver not loaded')
" 2>/dev/null

echo ""
echo "  All extended resources (capacity):"
oc get node lp-nvaie-rh-gpu03 -o json 2>/dev/null | python3 -c "
import json, sys
n = json.load(sys.stdin)
for k, v in sorted(n['status']['capacity'].items()):
    if k.startswith('nvidia') or k.startswith('gpu') or 'pci' in k.lower():
        print(f'    {k}: {v}')
" 2>/dev/null

# -------------------------------------------------------
section "5. HyperConverged Permitted Host Devices"
# -------------------------------------------------------
echo "  GPU/NVSwitch entries in permittedHostDevices:"
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.permittedHostDevices}' 2>/dev/null | python3 -m json.tool 2>/dev/null || \
  warn "Could not read HyperConverged permittedHostDevices"

# -------------------------------------------------------
section "6. GPU PCI Driver Binding on gpu03 (via debug pod)"
# -------------------------------------------------------
echo "  Current driver binding for NVIDIA PCI devices (10de:*):"
oc debug node/lp-nvaie-rh-gpu03 --quiet -- chroot /host bash -c '
  for d in /sys/bus/pci/devices/*; do
    vendor=$(cat "$d/vendor" 2>/dev/null)
    [ "$vendor" = "0x10de" ] || continue
    dev=$(basename $d)
    driver="(none)"
    if [ -L "$d/driver" ]; then
      driver=$(basename $(readlink "$d/driver"))
    fi
    class=$(cat "$d/class" 2>/dev/null)
    subsys=$(cat "$d/subsystem_device" 2>/dev/null)
    echo "$dev  driver=$driver  class=$class  subsys=$subsys"
  done | sort
' 2>/dev/null || warn "Debug pod failed — check node access manually"

# -------------------------------------------------------
section "7. OpenShift Virtualization Health"
# -------------------------------------------------------
HCO_STATUS=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
if [ "$HCO_STATUS" = "True" ]; then
  ok "HyperConverged Available=True"
else
  warn "HyperConverged Available=$HCO_STATUS"
fi

NOT_RUNNING=$(oc get pods -n openshift-cnv 2>/dev/null | grep -v -E "Running|Completed|NAME" | wc -l | tr -d ' ')
if [ "$NOT_RUNNING" -eq 0 ]; then
  ok "All openshift-cnv pods Running/Completed"
else
  warn "$NOT_RUNNING pod(s) in openshift-cnv not Running:"
  oc get pods -n openshift-cnv 2>/dev/null | grep -v -E "Running|Completed|NAME"
fi

# -------------------------------------------------------
section "8. Existing VMs in gpu-vms"
# -------------------------------------------------------
oc get vm,vmi -n gpu-vms -o wide 2>/dev/null || echo "  None found"

# -------------------------------------------------------
section "SUMMARY"
# -------------------------------------------------------
echo "  PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "  Fix FAILs before proceeding with VM creation."
fi
echo ""
echo "  ACTION: Share the output of this script to finalize the VM manifest."
