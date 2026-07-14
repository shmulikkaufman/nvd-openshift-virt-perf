# SNO + OpenShift Virtualization + GPU Passthrough — Complete Setup Guide

## Overview

This guide covers the full path from bare metal to running NVIDIA H100 GPU VMs on a
Single Node OpenShift (SNO) cluster, with additional worker nodes added later.

**Cluster layout:**

| Node | Role | Hostname | GPUs |
|------|------|----------|------|
| gpu02 | SNO control plane + worker | `lp-nvaie-rh-gpu02` | 8x H100 SXM5 + 4x NVSwitch |
| gpu03 | Worker (added later) | `lp-nvaie-rh-gpu03` | 8x H100 SXM5 + 4x NVSwitch |

**Environment details (gpu02 — primary node):**

| Item | Value |
|------|-------|
| OCP version | 4.22 |
| Node OS | RHEL CoreOS 9.8 |
| CPUs / RAM | 112 vCPUs / 252 GB |
| GPU model | NVIDIA H100 SXM5 80GB (`10de:2330`) |
| NVSwitch model | H100 NVSwitch (`10de:22a3`) |
| Management NIC | `ens12f0np0` → `lp-nvaie-rh-gpu02` |
| OVN NIC | `ens6f0np0` → enslaved into `br-ex` |
| Free NVMe | `/dev/nvme4n1` (3.5 TB) — used for LVMS |
| Bastion/launchpad | `global.prd.ga.launchpad.nvidia.com` as user `nvidia` |
| SNO kubeconfig | `~/.kube/config` on the bastion |

Adapt IP addresses, NIC names, GPU PCI IDs, and disk paths for your environment.

All Kubernetes manifests referenced in this guide live in the `manifests/` directory alongside this file. Apply them with `oc apply -f manifests/<file>` from the project root.

---

## Part 1 — SNO Installation

### 1.1 Prerequisites

- OpenShift pull secret from [console.redhat.com](https://console.redhat.com)
- `openshift-install` binary (matching target OCP version)
- SSH key pair

```bash
# Download openshift-install
OCP_VERSION=4.22.0
curl -Lo /tmp/ocp.tar.gz \
  https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-install-linux.tar.gz
tar -xzf /tmp/ocp.tar.gz -C /usr/local/bin openshift-install
openshift-install version
```

### 1.2 Network planning (critical for dual-NIC nodes)

SNO nodes with two or more NICs require careful planning. OVN-Kubernetes will
enslave one NIC into `br-ex`, changing its IP. The kubelet must bind to the
**management NIC IP**, not the OVN bridge IP.

Decide which NIC does what **before** installation:

| NIC | Role | IP |
|-----|------|----|
| `ens12f0np0` | Management (kubelet, API, etcd, SSH) | `lp-nvaie-rh-gpu02` |
| `ens6f0np0` | OVN external bridge (`br-ex`) | SNAT source |

The `rendezvousIP` in `agent-config.yaml` must match the **management NIC IP**.

### 1.3 Create the install directory and configuration files

```bash
mkdir -p ~/sno/install-dir
cd ~/sno
```

**`install-dir/install-config.yaml`:**

```yaml
apiVersion: v1
baseDomain: example.com          # your base domain
metadata:
  name: sno                      # cluster name — FQDN = sno.example.com
compute:
- name: worker
  replicas: 0                    # no workers in SNO
controlPlane:
  name: master
  replicas: 1                    # single control plane node
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
bootstrapInPlace:
  installationDisk: /dev/nvme3n1 # OS disk — NOT the disk you'll use for LVMS
pullSecret: '<your-pull-secret>' # from console.redhat.com
sshKey: '<your-ssh-public-key>'
```

**`install-dir/agent-config.yaml`:**

```yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: sno
rendezvousIP: 172.16.0.13        # management NIC IP — must match static IP below
hosts:
- hostname: lp-nvaie-rh-gpu02
  role: master
  interfaces:
  - name: ens12f0np0
    macAddress: "5c:25:73:97:17:30"   # MAC of the management NIC
  networkConfig:
    interfaces:
    - name: ens12f0np0
      type: ethernet
      state: up
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: 172.16.0.13
          prefix-length: 24
    dns-resolver:
      config:
        server:
        - 172.16.0.1
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: 172.16.0.1
        next-hop-interface: ens12f0np0
        table-id: 254
```

> **Note:** Only configure the management NIC in `agent-config.yaml`. Leave the
> OVN NIC unconfigured — OVN-Kubernetes will take ownership of it at install time.

### 1.4 Generate the agent ISO and boot

```bash
cd ~/sno
openshift-install agent create image --dir install-dir/

# The ISO is at: install-dir/agent.x86_64.iso
# Transfer it to a USB drive or mount it via IPMI/BMC virtual media
```

Boot the node from `agent.x86_64.iso`. The installation is fully automated.

Monitor progress (API becomes available ~15 minutes in):

```bash
openshift-install agent wait-for bootstrap-complete --dir install-dir/ --log-level=info
openshift-install agent wait-for install-complete --dir install-dir/ --log-level=info
```

Total install time: ~45–60 minutes.

### 1.5 Post-install access

```bash
export KUBECONFIG=~/.kube/config

# Verify node is Ready
oc get nodes

# Copy kubeconfig to the bastion home for convenience
cp ~/sno/install-dir/auth/kubeconfig ~/.kube/config
```

SSH to the node:

```bash
ssh core@lp-nvaie-rh-gpu02
```

---

## Part 2 — Critical Post-Install Fixes

### 2.1 The dual-NIC / OVN node-IP problem

On nodes with multiple NICs, OVN-Kubernetes runs `configure-ovs.sh` at startup
which rewrites `/etc/systemd/system/kubelet.service.d/20-nodenet.conf`. It sets
`KUBELET_NODE_IP` to the OVN bridge interface IP (`br-ex`, typically the second
NIC), not the management NIC.

This causes kubelet and etcd to bind to the wrong IP, breaking:
- Router pods (cannot reach `kubernetes` ClusterIP at `172.30.0.1:443`)
- etcd peer communication after any reboot
- Certificate SANs (certificates are issued for the wrong IP)

**The fix:** a higher-priority systemd drop-in (`21-node-ip-override.conf`) that
overrides `20-nodenet.conf` and survives every reboot, including MCO-triggered reboots.

### 2.2 Compute the base64 payload

On the bastion, encode the drop-in content:

```bash
NODE_IP="172.16.0.13"   # your management NIC IP

printf '[Service]\nEnvironment="KUBELET_NODE_IP=%s" "KUBELET_NODE_IPS=%s"\n' \
  "$NODE_IP" "$NODE_IP" | base64 -w0
```

Example output (for `172.16.0.13`):
```
W1NlcnZpY2VdCkVudmlyb25tZW50PSJLVUJFTEVUX05PREVfSVA9MTcyLjE2LjAuMTMiICJLVUJFTEVUX05PREVfSVBTPTE3Mi4xNi4wLjEzIgo=
```

### 2.3 Apply MachineConfig: permanent kubelet node-IP fix

This MachineConfig applies two fixes in one operation:

1. **Kubelet node-IP drop-in** (`21-node-ip-override.conf`) — hard-pins kubelet to the management NIC IP, overriding what OVN sets on every boot.
2. **`sno-iptables-fix.service`** — DNAT fix for host-network pod routing; prevents the console 503 crash-loop (see Troubleshooting).

> **Customize before applying:** The file encodes IP `172.16.0.13`. For a different management NIC IP, regenerate the base64:
> ```bash
> printf '[Service]\nEnvironment="KUBELET_NODE_IP=<IP>" "KUBELET_NODE_IPS=<IP>"\n' | base64 -w0
> ```
> Replace the `source:` base64 value and the `172.16.0.13` in the `ExecStart` line of `sno-iptables-fix.service`.

**`manifests/99-master-permanent-fixes.yaml`:**

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-permanent-fixes
spec:
  config:
    ignition:
      version: 3.5.0
    storage:
      files:
      - path: /etc/systemd/system/kubelet.service.d/21-node-ip-override.conf
        mode: 0644
        contents:
          source: "data:text/plain;charset=utf-8;base64,W1NlcnZpY2VdCkVudmlyb25tZW50PSJLVUJFTEVUX05PREVfSVA9MTcyLjE2LjAuMTMiICJLVUJFTEVUX05PREVfSVBTPTE3Mi4xNi4wLjEzIgo="
    systemd:
      units:
      - name: sno-iptables-fix.service
        enabled: true
        contents: |
          [Unit]
          Description=Fix Kubernetes ClusterIP routing for host-network pods
          After=network-online.target
          Wants=network-online.target
          [Service]
          Type=oneshot
          RemainAfterExit=yes
          ExecStart=/bin/bash -c '/sbin/iptables -t nat -C OUTPUT -d 172.30.0.1/32 -p tcp --dport 443 -j DNAT --to-destination 172.16.0.13:6443 2>/dev/null || /sbin/iptables -t nat -I OUTPUT 1 -d 172.30.0.1/32 -p tcp --dport 443 -j DNAT --to-destination 172.16.0.13:6443'
          [Install]
          WantedBy=multi-user.target
```

```bash
export KUBECONFIG=~/.kube/config
oc apply -f manifests/99-master-permanent-fixes.yaml
```

### 2.4 Apply MachineConfig: IOMMU kernel arguments

IOMMU is required for PCI passthrough. This MachineConfig adds
`intel_iommu=on iommu=pt` to the kernel command line.

**`manifests/100-master-iommu.yaml`:**

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 100-master-iommu
spec:
  config:
    ignition:
      version: 3.5.0
  kernelArguments:
  - intel_iommu=on
  - iommu=pt
```

> Use `amd_iommu=on` instead of `intel_iommu=on` on AMD systems.

```bash
oc apply -f manifests/100-master-iommu.yaml
```

### 2.5 Apply MachineConfig: bind GPUs and NVSwitches to vfio-pci

This unbinds the NVIDIA driver from the GPUs and NVSwitches at boot and binds
`vfio-pci` instead, making the devices available for VFIO passthrough. Two files
are written to the node:

| File | Content |
|------|---------|
| `/etc/modprobe.d/vfio.conf` | `softdep nvidia pre: vfio-pci` + `options vfio-pci ids=10de:2330,10de:22a3` |
| `/etc/modules-load.d/vfio-pci.conf` | `vfio-pci` |

The `softdep` line ensures `vfio-pci` loads before `nvidia` at boot, so it wins
the race to claim each PCI device.

Compute the base64 values:

```bash
printf 'softdep nvidia pre: vfio-pci\noptions vfio-pci ids=10de:2330,10de:22a3\n' | base64 -w0
# → c29mdGRlcCBudmlkaWEgcHJlOiB2ZmlvLXBjaQpvcHRpb25zIHZmaW8tcGNpIGlkcz0xMGRlOjIzMzAsMTBkZToyMmEzCg==

printf 'vfio-pci\n' | base64 -w0
# → dmZpby1wY2kK
```

**`manifests/100-master-vfio-pci-gpu-nvswitch.yaml`:**

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 100-master-vfio-pci-gpu
spec:
  config:
    ignition:
      version: 3.5.0
    storage:
      files:
      - path: /etc/modprobe.d/vfio.conf
        mode: 0644
        contents:
          # "softdep nvidia pre: vfio-pci\noptions vfio-pci ids=10de:2330,10de:22a3\n"
          source: "data:text/plain;charset=utf-8;base64,c29mdGRlcCBudmlkaWEgcHJlOiB2ZmlvLXBjaQpvcHRpb25zIHZmaW8tcGNpIGlkcz0xMGRlOjIzMzAsMTBkZToyMmEzCg=="
      - path: /etc/modules-load.d/vfio-pci.conf
        mode: 0644
        contents:
          source: "data:text/plain;charset=utf-8;base64,dmZpby1wY2kK"
```

```bash
oc apply -f manifests/100-master-vfio-pci-gpu-nvswitch.yaml
```

### 2.6 NVIDIA GPU Operator conflict with VFIO passthrough

> **Skip this section if the GPU Operator is not installed.** If it is installed,
> read this before rebooting — the operator will fight with VFIO and win silently.

When the NVIDIA GPU Operator is installed alongside OpenShift Virtualization, it
creates a conflict. By default the operator runs in *container workload mode*
(`sandboxWorkloads.enabled: false`), which means after every reboot it:

1. Loads the `nvidia` driver on the host
2. Actively rebinds GPUs from `vfio-pci` back to `nvidia`

The result: MachineConfig places the correct `softdep` and `vfio-pci ids=` in
modprobe.d, the node reboots — but GPUs end up on the `nvidia` driver, not
`vfio-pci`. The MachineConfig alone is not sufficient.

**Check whether the conflict is happening:**

```bash
oc debug node/lp-nvaie-rh-gpu02 -- chroot /host sh -c "
  for dev in \$(lspci -d 10de: -D | awk '{print \$1}'); do
    driver=\$(readlink /sys/bus/pci/devices/\$dev/driver 2>/dev/null | xargs basename 2>/dev/null || echo NONE)
    echo \"\$dev -> \$driver\"
  done"
# GPUs showing 'nvidia' instead of 'vfio-pci' means the operator is rebinding them.
```

**Fix: disable both `driver` and `vfioManager` in ClusterPolicy:**

```bash
oc patch clusterpolicy gpu-cluster-policy \
  --type=merge -p '{"spec":{"driver":{"enabled":false},"vfioManager":{"enabled":false}}}'
```

Then trigger a clean reboot by applying a no-op MachineConfig:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-vfio-active
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
      - path: /etc/vfio-pci-active
        mode: 0644
        contents:
          source: "data:text/plain;charset=utf-8,gpu-vfio-passthrough"
EOF
```

After the reboot, verify all GPUs and NVSwitches are on `vfio-pci` and no nvidia
modules are loaded on the host:

```bash
oc debug node/lp-nvaie-rh-gpu02 -- chroot /host sh -c "
  echo '=== PCI driver bindings ==='
  for dev in \$(lspci -d 10de: -D | awk '{print \$1}'); do
    driver=\$(readlink /sys/bus/pci/devices/\$dev/driver 2>/dev/null | xargs basename 2>/dev/null || echo NONE)
    desc=\$(lspci -d 10de: -s \$dev | cut -d: -f3-)
    echo \"\$dev -> \$driver |\$desc\"
  done
  echo '=== nvidia modules on host ==='
  lsmod | grep -E '^nvidia|^vfio' || echo none"
# Expected: all 12 devices -> vfio-pci, only vfio_* modules, zero nvidia modules
```

**Why disabling both components is required:**

| Component | Default | Effect |
|-----------|---------|--------|
| `driver` | enabled | Loads nvidia.ko on the host, claiming GPUs |
| `vfioManager` | enabled | In container mode, *unbinds* vfio-pci and *rebinds* nvidia on every boot |

Disabling only `vfioManager` is not enough — the driver daemonset still claims the
devices first. Both must be disabled together.

**Removing the GPU Operator entirely:**

With both components disabled, the operator's device-plugin pods are stuck in
`Init:0/1` (they can't initialize without nvidia-bound GPUs). The `nvidia.com/gpu`
and `nvidia.com/nvswitch` resource advertisements come from KubeVirt's device plugin
(via HCO `permittedHostDevices`), not from the GPU Operator. It is safe to remove:

```bash
oc delete clusterpolicy gpu-cluster-policy
oc delete subscription gpu-operator-certified -n nvidia-gpu-operator
oc delete csv -n nvidia-gpu-operator \
  $(oc get csv -n nvidia-gpu-operator -o name 2>/dev/null)
oc delete namespace nvidia-gpu-operator
```

Removing the operator does **not** affect VFIO bindings (MachineConfig), HCO
`permittedHostDevices`, or running VMs.

### 2.7 Wait for MCO to apply all MachineConfigs

Each `oc apply` above queues an MCO update. MCO batches them and reboots the
node once. On SNO, the entire cluster goes offline during the reboot.

```bash
# Watch MachineConfigPool — this will show UPDATING=True then go offline
oc get machineconfigpool master -w

# After the node reboots (~5 min), reconnect and verify
oc get machineconfigpool master
# Expected: UPDATED=True  UPDATING=False  DEGRADED=False
```

Verify the fixes are active on the node:

```bash
# IOMMU in kernel args
ssh core@lp-nvaie-rh-gpu02 'cat /proc/cmdline | grep -o "iommu[^ ]*\|intel_iommu[^ ]*"'
# Expected: intel_iommu=on  iommu=pt

# GPUs bound to vfio-pci
oc debug node/lp-nvaie-rh-gpu02 -- chroot /host \
  sh -c 'lspci -k | grep -A2 "10de:2330\|10de:22a3" | grep "Kernel driver"'
# Expected: Kernel driver in use: vfio-pci  (for all 12 devices)
```

---

## Part 3 — Storage (LVMS)

VMs need persistent block storage. LVMS (LVM Storage) provisions thin-provisioned
LVM volumes from bare NVMe disks and exposes them as a `topolvm.io` StorageClass.

### 3.1 Identify the free disk

```bash
oc debug node/lp-nvaie-rh-gpu02 -- chroot /host lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

The OS disk will have partitions with `/sysroot` or `/boot` mountpoints. All other
disks are candidates. Verify which device holds the VG (if one was pre-created):

```bash
oc debug node/lp-nvaie-rh-gpu02 -- chroot /host pvs
# e.g. /dev/nvme4n1   vmstorage  ...
```

> **Warning:** LVMS will fail if the disk has any existing filesystem signature
> (including `linux_raid_member`, `xfs`, `ext4`). Wipe it first if starting fresh:
>
> ```bash
> oc debug node/lp-nvaie-rh-gpu02 -- chroot /host wipefs -a /dev/nvme4n1
> ```

### 3.2 Install the LVMS Operator

**`manifests/lvms-install.yaml`:**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-storage
  namespace: openshift-storage
spec:
  targetNamespaces:
  - openshift-storage
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: openshift-storage
spec:
  name: lvms-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  channel: stable-4.22
  installPlanApproval: Automatic
```

> Adjust `channel` to match your OCP version: `oc get packagemanifest lvms-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}'`

```bash
oc apply -f manifests/lvms-install.yaml

# Wait for the operator pod to be Running
oc get pods -n openshift-storage -w
```

### 3.3 Create the LVMCluster

**`manifests/lvmcluster.yaml`:**

```yaml
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvmcluster
  namespace: openshift-storage
spec:
  tolerations:
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  storage:
    deviceClasses:
    - name: vmstorage
      default: true
      deviceSelector:
        paths:
        - /dev/nvme4n1      # adjust to your free NVMe disk
      thinPoolConfig:
        name: thin-pool
        sizePercent: 90
        overprovisionRatio: 10
      fstype: xfs
```

> If the VG `vmstorage` already exists on the disk, LVMS will adopt it automatically
> without reformatting. Verify with `pvs` before applying.

```bash
oc apply -f manifests/lvmcluster.yaml

# Wait for Ready
oc get lvmcluster -n openshift-storage -w
# Expected: STATUS=Ready
```

### 3.4 Create an Immediate-binding StorageClass for VMs

The default `lvms-vmstorage` StorageClass uses `WaitForFirstConsumer` binding,
which means PVCs don't bind until a pod is scheduled. For CDI (VM disk imports),
you need an `Immediate`-binding StorageClass so PVCs can be provisioned without
a running pod. This is also required when the VM runs on the SNO control-plane node.

**`manifests/lvms-immediate.yaml`:**

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: lvms-vmstorage-immediate
provisioner: topolvm.io
parameters:
  csi.storage.k8s.io/fstype: xfs
  topolvm.io/device-class: vmstorage
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

```bash
oc apply -f manifests/lvms-immediate.yaml

# Verify both StorageClasses exist
oc get storageclass
```

### 3.5 Verify storage works end-to-end

```bash
cat > /tmp/test-pvc.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: lvms-vmstorage-immediate
  volumeMode: Block
  resources:
    requests:
      storage: 1Gi
EOF

oc apply -f /tmp/test-pvc.yaml
oc get pvc test-pvc -n default
# Expected: STATUS=Bound within ~10s

oc delete pvc test-pvc -n default
```

---

## Part 4 — OpenShift Virtualization

### 4.1 Install the Operator

**`manifests/cnv-install.yaml`:**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: stable
  installPlanApproval: Automatic
```

```bash
oc apply -f manifests/cnv-install.yaml

# Wait for the CSV to reach Succeeded (~3-5 min)
oc get csv -n openshift-cnv -w | grep kubevirt
```

### 4.2 Create the HyperConverged CR

This deploys all components: KubeVirt, CDI, SSP, and supporting controllers.

**`manifests/hyperconverged.yaml`:**

```yaml
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
```

```bash
oc apply -f manifests/hyperconverged.yaml

# Watch components come up (~5-10 min)
oc get pods -n openshift-cnv -w

# Check HyperConverged is Available
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' && echo ""
# Expected: True
```

### 4.3 Install virtctl

```bash
# virtctl is available from the cluster's built-in download route
ROUTE=$(oc get route hyperconverged-cluster-cli-download -n openshift-cnv \
  -o jsonpath='{.spec.host}')

curl -Lo /tmp/virtctl "https://${ROUTE}/amd64/linux/virtctl"
chmod +x /tmp/virtctl
sudo mv /tmp/virtctl /usr/local/bin/virtctl

virtctl version
```

### 4.4 Configure GPU and NVSwitch passthrough (permittedHostDevices)

Get the PCI IDs:

```bash
oc debug node/lp-nvaie-rh-gpu02 -- chroot /host \
  sh -c 'lspci -nn | grep -i nvidia'
# Example:
# 1b:00.0 3D controller [0302]: NVIDIA Corporation GH100 [H100 SXM5 80GB] [10de:2330] (rev a1)
# 07:00.0 Bridge [0604]: NVIDIA Corporation GH100 [H100 NVSwitch] [10de:22a3] (rev a1)
```

> **Important — use `v1beta1`:** Patching via the default `v1` API silently prunes
> `permittedHostDevices` because the v1 CRD schema does not define the field.
> The storage version is `v1beta1`. Always use `kubectl patch hyperconverged.v1beta1.hco.kubevirt.io`.

```bash
# Add GPU
kubectl patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv --type=json \
  -p='[{"op":"add","path":"/spec/permittedHostDevices",
        "value":{"pciHostDevices":[
          {"pciDeviceSelector":"10de:2330","resourceName":"nvidia.com/gpu"},
          {"pciDeviceSelector":"10de:22a3","resourceName":"nvidia.com/nvswitch"}
        ]}}]'

# Verify stored in HCO (v1beta1)
kubectl get hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv -o jsonpath='{.spec.permittedHostDevices}' | python3 -m json.tool

# Node should advertise both resource types (~60s for device plugin to update)
oc describe node lp-nvaie-rh-gpu02 | grep "nvidia.com"
# Expected:
#   nvidia.com/gpu:      8
#   nvidia.com/nvswitch: 4
```

---

## Part 5 — CDI Orphan Fix (apply only if CDI is not deploying)

### 5.1 Symptom

After installing OpenShift Virtualization, if CDI-related pods (beyond `cdi-operator`)
never appear and the HyperConverged status shows:

```
SSP is degraded: Required CRDs are missing: datasources.cdi.kubevirt.io, dataimportcrons.cdi.kubevirt.io
```

Check the CDI operator logs:

```bash
oc logs -n openshift-cnv deployment/cdi-operator --tail=20
```

If every line repeats:

```
"msg":"Orphan object exists","obj":{"kind":"ConfigMap","name":"cdi-apiserver-signer-bundle"}
```

the CDI operator is stuck in a loop and will not deploy CDI components.

### 5.2 Fix

The orphaned ConfigMap was left from a previous CDI installation. Deleting it
unblocks the reconciliation loop:

```bash
oc delete configmap cdi-apiserver-signer-bundle -n openshift-cnv
```

Within ~15 seconds, CDI components appear:

```bash
oc get pods -n openshift-cnv | grep cdi
# Expected:
# cdi-apiserver-*      1/1  Running
# cdi-deployment-*     1/1  Running
# cdi-uploadproxy-*    1/1  Running
# cdi-operator-*       1/1  Running
```

---

## Part 6 — Create a RHEL 9 GPU VM

### 6.1 Create the VM namespace

```bash
oc new-project gpu-vms
```

### 6.2 Prepare registry credentials for CDI

CDI needs access to `registry.redhat.io` to import the RHEL 9 guest image.

```bash
eval "$(oc get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | \
  python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
auth = d['auths']['registry.redhat.io']['auth']
user, pw = base64.b64decode(auth).decode().split(':', 1)
print(f'RH_USER={user}')
print(f'RH_PW={pw}')")"

oc create secret generic redhat-registry-pull-secret \
  -n openshift-virtualization-os-images \
  --from-literal=accessKeyId="$RH_USER" \
  --from-literal=secretKey="$RH_PW"
```

### 6.3 Import the RHEL 9 golden image

**`manifests/dv-rhel9-golden.yaml`:**

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: rhel9-guest
  namespace: openshift-virtualization-os-images
spec:
  source:
    registry:
      url: "docker://registry.redhat.io/rhel9/rhel-guest-image@sha256:7005186c23b8f9bcaf7b068dc99b88e0fc33d54e4073c494f547c55835256374"
      secretRef: redhat-registry-pull-secret
  storage:
    resources:
      requests:
        storage: 50Gi
    storageClassName: lvms-vmstorage-immediate
    accessModes:
    - ReadWriteOnce
    volumeMode: Block
```

```bash
oc apply -f manifests/dv-rhel9-golden.yaml

# Watch import progress
oc get datavolume rhel9-guest -n openshift-virtualization-os-images -w
# Wait for: PHASE=Succeeded  PROGRESS=100.0%
```

### 6.4 Create the VirtualMachine

Before applying, edit `manifests/vm-rhel9-gpu.yaml` and replace `<YOUR_SSH_PUBLIC_KEY>`
with your actual public key.

**`manifests/vm-rhel9-gpu.yaml`:**

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: rhel9-gpu-vm
  namespace: gpu-vms
  labels:
    app: rhel9-gpu-vm
spec:
  runStrategy: Always
  dataVolumeTemplates:
  - metadata:
      name: rhel9-gpu-vm-disk
    spec:
      source:
        pvc:
          name: rhel9-guest
          namespace: openshift-virtualization-os-images
      storage:
        resources:
          requests:
            storage: 50Gi
        storageClassName: lvms-vmstorage-immediate
        accessModes:
        - ReadWriteOnce
        volumeMode: Block
  template:
    metadata:
      labels:
        kubevirt.io/vm: rhel9-gpu-vm
    spec:
      architecture: amd64
      domain:
        cpu:
          cores: 16
          sockets: 1
          threads: 1
        machine:
          type: q35
        memory:
          guest: 64Gi
        resources:
          requests:
            memory: 64Gi
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
          - name: cloudinit
            disk:
              bus: virtio
          interfaces:
          - name: default
            masquerade: {}
          hostDevices:
          - name: gpu-0
            deviceName: nvidia.com/gpu
          - name: gpu-1
            deviceName: nvidia.com/gpu
          - name: gpu-2
            deviceName: nvidia.com/gpu
          - name: gpu-3
            deviceName: nvidia.com/gpu
          - name: gpu-4
            deviceName: nvidia.com/gpu
          - name: gpu-5
            deviceName: nvidia.com/gpu
          - name: gpu-6
            deviceName: nvidia.com/gpu
          - name: gpu-7
            deviceName: nvidia.com/gpu
          - name: nvswitch-0
            deviceName: nvidia.com/nvswitch
          - name: nvswitch-1
            deviceName: nvidia.com/nvswitch
          - name: nvswitch-2
            deviceName: nvidia.com/nvswitch
          - name: nvswitch-3
            deviceName: nvidia.com/nvswitch
      networks:
      - name: default
        pod: {}
      volumes:
      - name: rootdisk
        dataVolume:
          name: rhel9-gpu-vm-disk
      - name: cloudinit
        cloudInitNoCloud:
          userData: |
            #cloud-config
            user: cloud-user
            password: redhat123
            chpasswd:
              expire: false
            ssh_pwauth: true
            ssh_authorized_keys:
            - <YOUR_SSH_PUBLIC_KEY>
```

```bash
oc apply -f manifests/vm-rhel9-gpu.yaml
```

### 6.5 Monitor disk clone and VM startup

```bash
oc get datavolume rhel9-gpu-vm-disk -n gpu-vms -w
# Wait for: PHASE=Succeeded  PROGRESS=100.0%

oc get vmi rhel9-gpu-vm -n gpu-vms -w
# Wait for: PHASE=Running
```

### 6.6 SSH into the VM

```bash
virtctl ssh cloud-user@vm/rhel9-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'
```

---

## Part 7 — Install NVIDIA Drivers in the RHEL 9 Guest VM

### 7.1 Enable RHEL repos using cluster entitlement certs

On the **bastion**, extract the certs and copy them into the VM:

```bash
export KUBECONFIG=~/.kube/config

oc get secret etc-pki-entitlement -n openshift-config-managed \
  -o jsonpath='{.data.entitlement\.pem}' | base64 -d > /tmp/entitlement.pem

oc get secret etc-pki-entitlement -n openshift-config-managed \
  -o jsonpath='{.data.entitlement-key\.pem}' | base64 -d > /tmp/entitlement-key.pem

virtctl scp /tmp/entitlement.pem \
  cloud-user@vm/rhel9-gpu-vm/gpu-vms:/tmp/ \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

virtctl scp /tmp/entitlement-key.pem \
  cloud-user@vm/rhel9-gpu-vm/gpu-vms:/tmp/ \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'
```

**Inside the VM**, place the certs and configure repos:

```bash
sudo mkdir -p /etc/pki/entitlement
sudo cp /tmp/entitlement.pem /etc/pki/entitlement/
sudo cp /tmp/entitlement-key.pem /etc/pki/entitlement/

sudo tee /etc/yum.repos.d/rhel9-entitled.repo << 'EOF'
[rhel-9-baseos]
name=RHEL 9 BaseOS
baseurl=https://cdn.redhat.com/content/dist/rhel9/9/x86_64/baseos/os
enabled=1
gpgcheck=1
sslverify=1
sslclientcert=/etc/pki/entitlement/entitlement.pem
sslclientkey=/etc/pki/entitlement/entitlement-key.pem
sslcacert=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

[rhel-9-appstream]
name=RHEL 9 AppStream
baseurl=https://cdn.redhat.com/content/dist/rhel9/9/x86_64/appstream/os
enabled=1
gpgcheck=1
sslverify=1
sslclientcert=/etc/pki/entitlement/entitlement.pem
sslclientkey=/etc/pki/entitlement/entitlement-key.pem
sslcacert=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

[rhel-9-crb]
name=RHEL 9 CRB
baseurl=https://cdn.redhat.com/content/dist/rhel9/9/x86_64/codeready-builder/os
enabled=1
gpgcheck=1
sslverify=1
sslclientcert=/etc/pki/entitlement/entitlement.pem
sslclientkey=/etc/pki/entitlement/entitlement-key.pem
sslcacert=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
EOF

sudo dnf repolist
```

### 7.2 Add EPEL and the NVIDIA CUDA repo

```bash
sudo dnf install -y \
  https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

sudo dnf config-manager --add-repo \
  https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo

sudo dnf makecache
```

### 7.3 Install build tools and NVIDIA open kernel modules

H100 (Hopper/GH100) requires the **open** kernel modules.

```bash
sudo dnf install -y \
  kernel-devel-$(uname -r) \
  kernel-headers-$(uname -r) \
  gcc make dkms \
  nvidia-open \
  nvidia-driver-cuda

sudo reboot
```

### 7.4 Verify

```bash
nvidia-smi
# Expected: 8x NVIDIA H100 80GB HBM3 listed
```

### 7.5 Create and compile the CUDA smoke test

See Part 9.7 for the full source code. The same `gpu_test.cu` works on both RHEL 9 and Ubuntu VMs.

```bash
virtctl scp gpu_test.cu cloud-user@vm/rhel9-gpu-vm/gpu-vms:/home/cloud-user/ \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

virtctl ssh cloud-user@vm/rhel9-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' \
  -c 'export PATH=/usr/local/cuda/bin:$PATH; nvcc -O2 -o gpu_test gpu_test.cu && ./gpu_test'
```

---

## Part 8 — NVSwitch Passthrough and NVIDIA Fabric Manager

H100 SXM5 GPUs are physically connected to NVSwitches via NVLink. Without NVSwitch
hardware accessible to the VM, CUDA returns `CUDA_ERROR_SYSTEM_NOT_READY` (error 802)
because `cuInit()` waits for the NVIDIA Fabric Manager, which requires NVSwitch access.

NVSwitch passthrough is already included in the MachineConfig from Part 2.5 and the
`permittedHostDevices` config from Part 4.4 (PCI ID `10de:22a3`). Once the VM has all
4 NVSwitches passed through, install Fabric Manager inside the guest — see Part 9.5
Step 2 for the exact package installation procedure.

### 8.1 Verify NVSwitches inside a running VM

```bash
virtctl ssh ubuntu@vm/ubuntu2404-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' \
  -c 'lspci | grep -iE "nvidia|3d|bridge"'
# Expected: 8x 3D controller (GPUs) + 4x Bridge (NVSwitches)
```

### 8.2 Troubleshooting: `cuInit` returns error 802

This means Fabric Manager is not running or failed to configure the NVSwitches.

```bash
sudo systemctl status nvidia-fabricmanager
sudo journalctl -u nvidia-fabricmanager --no-pager -n 50
sudo systemctl restart nvidia-fabricmanager
```

FM requires `/dev/nvidia-nvswitch*` device nodes. These appear automatically when the
NVIDIA driver detects NVSwitch PCI devices. If they are missing:

```bash
lspci | grep -i nvswitch    # NVSwitches must be visible as PCI devices
ls /dev/nvidia-nvswitch*    # Device nodes must exist after driver loads
```

### 8.3 HCO removes NVSwitch from KubeVirt within 1 second

This happens when patching via the default `v1` API. Fix: always patch via `v1beta1`
as shown in Part 4.4.

```bash
# Verify the HCO CR actually has the entry stored
kubectl get hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv -o jsonpath='{.spec.permittedHostDevices}' | python3 -m json.tool
```

---

## Part 9 — Ubuntu 24.04 LTS GPU VM on gpu02 (SNO Control Plane Node)

This part deploys an Ubuntu 24.04 VM with all 8 H100 SXM5 GPUs and 4 NVSwitches
passed through via VFIO on the SNO node (gpu02), which serves as both control plane
and worker. No separate GPU node is needed.

> **SNO storage note:** Use `lvms-vmstorage-immediate` (Immediate binding) instead of
> `lvms-vmstorage` (WaitForFirstConsumer). On a single-node cluster the scheduler cannot
> satisfy WaitForFirstConsumer constraints for control-plane workloads.

### 9.1 Create the VM namespace

```bash
oc new-project gpu-vms
```

### 9.2 Create the Ubuntu 24.04 VM

The VM imports Ubuntu 24.04 Noble directly from the Ubuntu cloud image archive.
No `nodeSelector` is needed — on SNO there is only one schedulable node.

**`manifests/vm-ubuntu2404-gpu.yaml`:**

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ubuntu2404-gpu-vm
  namespace: gpu-vms
  labels:
    app: ubuntu2404-gpu-vm
spec:
  runStrategy: Always
  dataVolumeTemplates:
  - metadata:
      name: ubuntu2404-gpu-vm-disk
    spec:
      source:
        http:
          url: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
      storage:
        resources:
          requests:
            storage: 80Gi
        storageClassName: lvms-vmstorage-immediate
        accessModes:
        - ReadWriteOnce
        volumeMode: Block
  template:
    metadata:
      labels:
        kubevirt.io/vm: ubuntu2404-gpu-vm
    spec:
      architecture: amd64
      domain:
        cpu:
          cores: 16
          sockets: 1
          threads: 1
        machine:
          type: q35
        memory:
          guest: 64Gi
        resources:
          requests:
            memory: 64Gi
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
          - name: cloudinit
            disk:
              bus: virtio
          interfaces:
          - name: default
            masquerade: {}
          hostDevices:
          - name: gpu-0
            deviceName: nvidia.com/gpu
          - name: gpu-1
            deviceName: nvidia.com/gpu
          - name: gpu-2
            deviceName: nvidia.com/gpu
          - name: gpu-3
            deviceName: nvidia.com/gpu
          - name: gpu-4
            deviceName: nvidia.com/gpu
          - name: gpu-5
            deviceName: nvidia.com/gpu
          - name: gpu-6
            deviceName: nvidia.com/gpu
          - name: gpu-7
            deviceName: nvidia.com/gpu
          - name: nvswitch-0
            deviceName: nvidia.com/nvswitch
          - name: nvswitch-1
            deviceName: nvidia.com/nvswitch
          - name: nvswitch-2
            deviceName: nvidia.com/nvswitch
          - name: nvswitch-3
            deviceName: nvidia.com/nvswitch
      networks:
      - name: default
        pod: {}
      volumes:
      - name: rootdisk
        dataVolume:
          name: ubuntu2404-gpu-vm-disk
      - name: cloudinit
        cloudInitNoCloud:
          userData: |
            #cloud-config
            user: ubuntu
            password: ubuntu123
            chpasswd:
              expire: false
            ssh_pwauth: true
            ssh_authorized_keys:
            - <YOUR_SSH_PUBLIC_KEY>
```

```bash
oc apply -f manifests/vm-ubuntu2404-gpu.yaml

# Monitor image download (~600 MB compressed)
oc get datavolume ubuntu2404-gpu-vm-disk -n gpu-vms -w
# Wait for: PHASE=Succeeded  PROGRESS=100.0%

# Watch VM come up
oc get vmi ubuntu2404-gpu-vm -n gpu-vms -w
# Wait for: PHASE=Running
```

### 9.3 SSH into the Ubuntu VM

```bash
# Format: <user>@vm/<vmname>/<namespace>
virtctl ssh ubuntu@vm/ubuntu2404-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'
```

> **virtctl ssh syntax notes:**
> - Target format is `<user>@vm/<name>/<namespace>` — not `vmi/` and not `-n <ns>` as a separate flag
> - Use `-t '-o StrictHostKeyChecking=no'` (not `--local-ssh-opts`)
> - Use `--known-hosts=''` to skip known_hosts checking (needed after VM restarts)

### 9.4 Install prerequisites on Ubuntu 24.04

Target versions used in this environment:

| Component | Version |
|-----------|---------|
| OS | Ubuntu 24.04 LTS |
| Kernel | 6.8.0-x-generic |
| NVIDIA Driver | 580.x (open kernel modules, DKMS) |
| Fabric Manager | matching driver version |
| CUDA Toolkit | 13.0 |

#### Step 1 — NVIDIA driver (open kernel modules)

H100/Hopper requires open kernel modules. Install from the NVIDIA CUDA repo.

```bash
# Add NVIDIA CUDA repository
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-cuda.gpg
echo "deb [signed-by=/usr/share/keyrings/nvidia-cuda.gpg] \
  https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /" \
  | sudo tee /etc/apt/sources.list.d/nvidia-cuda.list

sudo apt-get update
sudo apt-get install -y linux-headers-$(uname -r)

# Check what version is available before installing
apt-cache madison nvidia-open-580 | head -5

# Install — apt will resolve to the latest available 580.x patch
sudo apt-get install -y nvidia-open-580

# Make the driver auto-load at boot (DKMS does not add this automatically)
echo nvidia | sudo tee /etc/modules-load.d/nvidia.conf

sudo reboot
```

After reboot, verify the driver loaded:

```bash
cat /proc/driver/nvidia/version
# Expected: NVIDIA UNIX Open Kernel Module ... 580.x.xx

nvidia-smi
# Expected: 8x NVIDIA H100 80GB HBM3 listed
```

> **Driver version note:** `apt` may resolve a newer patch than specified (e.g.
> `580.173.02` instead of `580.126.20`). This is fine — record the actual installed
> version and use it for Fabric Manager in the next step.

#### Step 2 — NVIDIA Fabric Manager

Fabric Manager is required for H100 SXM5 with NVSwitch. Without it `cuInit()`
fails with error 802 (`CUDA_ERROR_SYSTEM_NOT_READY`). The version **must exactly
match** the installed driver.

```bash
# Read the actual installed driver version
DRIVER_VER=$(cat /proc/driver/nvidia/version | awk '{print $8}')
echo "Driver version: $DRIVER_VER"

# Install matching Fabric Manager
# Ubuntu packages use the '-1ubuntu1' suffix (not plain '-1')
sudo apt-get install -y nvidia-fabricmanager=${DRIVER_VER}-1ubuntu1

sudo systemctl enable nvidia-fabricmanager
sudo systemctl start nvidia-fabricmanager

# Verify — look for "Connected to 1 node" and "Successfully configured NVSwitches"
sudo systemctl status nvidia-fabricmanager --no-pager
sudo journalctl -u nvidia-fabricmanager --no-pager -n 10
```

Expected FM log lines:

```
Connected to 1 node.
Successfully configured all the available NVSwitches to route GPU NVLink traffic.
```

#### Step 3 — CUDA Toolkit 13.0

```bash
sudo apt-get install -y cuda-toolkit-13-0

echo 'export PATH=/usr/local/cuda-13.0/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda-13.0/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
source ~/.bashrc

nvcc --version
# Expected: Cuda compilation tools, release 13.0, V13.0.88
```

### 9.5 Verify all components

```bash
# OS
lsb_release -d

# Kernel
uname -r

# Driver
cat /proc/driver/nvidia/version | head -1

# All 8 GPUs + NVLink status
nvidia-smi
nvidia-smi nvlink -s | head -20

# Fabric Manager
sudo systemctl status nvidia-fabricmanager --no-pager | grep Active

# CUDA
nvcc --version
```

Expected summary:

| Component | Expected |
|-----------|----------|
| OS | Ubuntu 24.04 LTS |
| Driver | 580.x open kernel module |
| GPUs | 8 × NVIDIA H100 SXM5 80GB |
| NVLink | 18 links × 26.562 GB/s per GPU |
| Fabric Manager | active (running) |
| CUDA | release 13.0 |

### 9.6 Build and run the CUDA smoke test

```bash
# Copy gpu_test.cu to the VM (run from bastion)
virtctl scp gpu_test.cu ubuntu@vm/ubuntu2404-gpu-vm/gpu-vms:/home/ubuntu/ \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

# Compile and run inside the VM
virtctl ssh ubuntu@vm/ubuntu2404-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' \
  -c 'export PATH=/usr/local/cuda/bin:$PATH; nvcc -O2 -o gpu_test gpu_test.cu && ./gpu_test'
```

Expected: `Found 8 GPU(s)` followed by per-GPU info and `Result: PASS`.

### 9.7 CUDA smoke test source (gpu_test.cu)

```c
#include <stdio.h>
#include <cuda_runtime.h>

#define N (1 << 24)   // 16M elements
#define THREADS 256

__global__ void vector_add(const float *a, const float *b, float *c, int n) {
    int i = blockDim.x * blockIdx.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

static void check(cudaError_t err, const char *file, int line) {
    if (err != cudaSuccess) {
        fprintf(stderr, "CUDA error %s:%d: %s\n", file, line, cudaGetErrorString(err));
        exit(1);
    }
}
#define CHECK(x) check((x), __FILE__, __LINE__)

static void print_device_info(int dev) {
    cudaDeviceProp p;
    CHECK(cudaGetDeviceProperties(&p, dev));
    size_t free_mem, total_mem;
    CHECK(cudaMemGetInfo(&free_mem, &total_mem));
    printf("=== GPU %d: %s ===\n", dev, p.name);
    printf("  Compute capability : %d.%d\n", p.major, p.minor);
    printf("  SMs                : %d\n", p.multiProcessorCount);
    printf("  Memory (GiB)       : %.1f total, %.1f free\n",
           total_mem / 1073741824.0, free_mem / 1073741824.0);
    printf("  ECC enabled        : %s\n", p.ECCEnabled ? "yes" : "no");
    printf("  Peer access        : ");
    int count; cudaGetDeviceCount(&count); int any = 0;
    for (int i = 0; i < count; i++) {
        if (i == dev) continue;
        int can; cudaDeviceCanAccessPeer(&can, dev, i);
        if (can) { printf("%d ", i); any = 1; }
    }
    if (!any) printf("none");
    printf("\n");
}

int main(void) {
    int count;
    CHECK(cudaGetDeviceCount(&count));
    printf("Found %d GPU(s)\n\n", count);
    for (int i = 0; i < count; i++) print_device_info(i);

    printf("\n=== Vector addition: %dM floats ===\n", N >> 20);
    float *h_a = malloc(N * sizeof(float)), *h_b = malloc(N * sizeof(float)),
          *h_c = malloc(N * sizeof(float));
    for (int i = 0; i < N; i++) { h_a[i] = 1.0f; h_b[i] = 2.0f; }

    float *d_a, *d_b, *d_c;
    CHECK(cudaMalloc(&d_a, N * sizeof(float)));
    CHECK(cudaMalloc(&d_b, N * sizeof(float)));
    CHECK(cudaMalloc(&d_c, N * sizeof(float)));

    cudaEvent_t t0, t1;
    CHECK(cudaEventCreate(&t0)); CHECK(cudaEventCreate(&t1));
    CHECK(cudaMemcpy(d_a, h_a, N * sizeof(float), cudaMemcpyHostToDevice));
    CHECK(cudaMemcpy(d_b, h_b, N * sizeof(float), cudaMemcpyHostToDevice));

    int blocks = (N + THREADS - 1) / THREADS;
    CHECK(cudaEventRecord(t0));
    vector_add<<<blocks, THREADS>>>(d_a, d_b, d_c, N);
    CHECK(cudaEventRecord(t1));
    CHECK(cudaEventSynchronize(t1));
    CHECK(cudaGetLastError());

    float ms; CHECK(cudaEventElapsedTime(&ms, t0, t1));
    double gb = 3.0 * N * sizeof(float) / 1e9;
    printf("  Kernel time  : %.3f ms\n", ms);
    printf("  Bandwidth    : %.1f GB/s\n", gb / (ms / 1000.0));

    CHECK(cudaMemcpy(h_c, d_c, N * sizeof(float), cudaMemcpyDeviceToHost));
    int errors = 0;
    for (int i = 0; i < N; i++) if (h_c[i] != 3.0f) errors++;
    printf("  Errors       : %d\n", errors);
    printf("  Result       : %s\n\n", errors == 0 ? "PASS" : "FAIL");

    cudaFree(d_a); cudaFree(d_b); cudaFree(d_c);
    free(h_a); free(h_b); free(h_c);
    cudaEventDestroy(t0); cudaEventDestroy(t1);
    return errors != 0;
}
```

---

## Part 10 — Add gpu03 as a Worker Node and Launch a Second Ubuntu VM

gpu03 is a second identical bare metal node with its own 8 H100 SXM5 GPUs and 4
NVSwitches. Adding it as a worker extends the cluster and lets you deploy a second
Ubuntu VM without sharing devices with the gpu02 VM.

### 10.1 Add gpu03 to the cluster

Generate a worker agent ISO and boot gpu03 from it. The worker joins the existing
SNO control plane without disrupting gpu02.

```bash
# On the bastion — create worker agent ISO
mkdir -p ~/sno/worker-install-dir
cp ~/sno/install-dir/auth/kubeconfig ~/sno/worker-install-dir/

cat > ~/sno/worker-install-dir/agent-config.yaml << 'EOF'
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: sno
hosts:
- hostname: lp-nvaie-rh-gpu03
  role: worker
  interfaces:
  - name: ens12f0np0
    macAddress: "<gpu03-management-nic-mac>"
  networkConfig:
    interfaces:
    - name: ens12f0np0
      type: ethernet
      state: up
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: <gpu03-management-ip>
          prefix-length: 24
    dns-resolver:
      config:
        server:
        - <dns-server>
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: <gateway>
        next-hop-interface: ens12f0np0
        table-id: 254
EOF

openshift-install agent create image --dir ~/sno/worker-install-dir/
```

Boot gpu03 from the ISO. The node will discover the existing cluster and join automatically.

```bash
# Watch the node appear and become Ready (~10 minutes)
oc get nodes -w
# Expected: lp-nvaie-rh-gpu03  Ready  worker  ...
```

### 10.2 Apply worker MachineConfigs for IOMMU and vfio-pci

The master MachineConfigs from Part 2 only target `role: master` (gpu02). gpu03
needs equivalent configs targeting `role: worker`.

**`manifests/100-worker-iommu.yaml`:**

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 100-worker-iommu
spec:
  config:
    ignition:
      version: 3.5.0
  kernelArguments:
  - intel_iommu=on
  - iommu=pt
```

**`manifests/100-worker-vfio-pci-gpu-nvswitch.yaml`:**

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 100-worker-vfio-pci-gpu
spec:
  config:
    ignition:
      version: 3.5.0
    storage:
      files:
      - path: /etc/modprobe.d/vfio.conf
        mode: 0644
        contents:
          # "softdep nvidia pre: vfio-pci\noptions vfio-pci ids=10de:2330,10de:22a3\n"
          source: "data:text/plain;charset=utf-8;base64,c29mdGRlcCBudmlkaWEgcHJlOiB2ZmlvLXBjaQpvcHRpb25zIHZmaW8tcGNpIGlkcz0xMGRlOjIzMzAsMTBkZToyMmEzCg=="
      - path: /etc/modules-load.d/vfio-pci.conf
        mode: 0644
        contents:
          source: "data:text/plain;charset=utf-8;base64,dmZpby1wY2kK"
```

```bash
oc apply -f manifests/100-worker-iommu.yaml
oc apply -f manifests/100-worker-vfio-pci-gpu-nvswitch.yaml

# Watch worker MachineConfigPool — gpu03 will reboot
oc get machineconfigpool worker -w
# Expected: UPDATED=True  UPDATING=False  DEGRADED=False

# Verify after reboot
oc debug node/lp-nvaie-rh-gpu03 -- chroot /host sh -c "
  for dev in \$(lspci -d 10de: -D | awk '{print \$1}'); do
    driver=\$(readlink /sys/bus/pci/devices/\$dev/driver 2>/dev/null | xargs basename 2>/dev/null || echo NONE)
    echo \"\$dev -> \$driver\"
  done"
# Expected: all 12 devices -> vfio-pci
```

> **GPU Operator conflict on gpu03:** If the GPU Operator is installed cluster-wide,
> apply the same ClusterPolicy fix from Part 2.6 before the worker MachineConfigs
> take effect. The ClusterPolicy is cluster-scoped, so disabling `driver` and
> `vfioManager` applies to all nodes including gpu03.

### 10.3 Configure LVMS storage on gpu03

gpu03 needs its own LVMS device class. The existing `LVMCluster` on gpu02 uses the
`vmstorage` device class — add gpu03's free NVMe as a second device class, or extend
the existing cluster to include it.

First, identify the free disk on gpu03:

```bash
oc debug node/lp-nvaie-rh-gpu03 -- chroot /host pvs 2>/dev/null
oc debug node/lp-nvaie-rh-gpu03 -- chroot /host lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

Patch the existing LVMCluster to add gpu03's device (or create a second device class):

```bash
# If gpu03 has the same VG name 'vmstorage' on its free disk (e.g. /dev/nvme4n1):
oc patch lvmcluster lvmcluster -n openshift-storage --type=merge -p '{
  "spec": {
    "storage": {
      "deviceClasses": [{
        "name": "vmstorage",
        "default": true,
        "deviceSelector": {"paths": ["/dev/nvme4n1"]},
        "thinPoolConfig": {"name": "thin-pool", "sizePercent": 90, "overprovisionRatio": 10},
        "fstype": "xfs"
      }]
    }
  }
}'

oc get lvmcluster -n openshift-storage
# Expected: STATUS=Ready
```

The `lvms-vmstorage` and `lvms-vmstorage-immediate` StorageClasses are already
present from Part 3 and are topology-aware — PVCs will be provisioned on whichever
node the VM schedules to.

### 10.4 Verify gpu03 advertises GPU and NVSwitch capacity

The HCO `permittedHostDevices` configuration from Part 4.4 is cluster-scoped.
Once gpu03's devices are bound to `vfio-pci` and the virt-handler device plugin
restarts, the node will automatically advertise `nvidia.com/gpu: 8` and
`nvidia.com/nvswitch: 4`.

```bash
oc describe node lp-nvaie-rh-gpu03 | grep "nvidia.com"
# Expected:
#   nvidia.com/gpu:      8
#   nvidia.com/nvswitch: 4
```

### 10.5 Create the Ubuntu VM on gpu03

The VM spec is identical to the gpu02 VM with two differences:
- `nodeSelector` pins it to gpu03 so it doesn't compete with the gpu02 VM for devices
- StorageClass can use `lvms-vmstorage` (WaitForFirstConsumer is fine on a worker node)

**`manifests/vm-ubuntu2404-gpu-gpu03.yaml`:**

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ubuntu2404-gpu-vm-gpu03
  namespace: gpu-vms
  labels:
    app: ubuntu2404-gpu-vm-gpu03
spec:
  runStrategy: Always
  dataVolumeTemplates:
  - metadata:
      name: ubuntu2404-gpu-vm-gpu03-disk
    spec:
      source:
        http:
          url: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
      storage:
        resources:
          requests:
            storage: 80Gi
        storageClassName: lvms-vmstorage
        accessModes:
        - ReadWriteOnce
        volumeMode: Block
  template:
    metadata:
      labels:
        kubevirt.io/vm: ubuntu2404-gpu-vm-gpu03
    spec:
      architecture: amd64
      nodeSelector:
        kubernetes.io/hostname: lp-nvaie-rh-gpu03
      domain:
        cpu:
          cores: 16
          sockets: 1
          threads: 1
        machine:
          type: q35
        memory:
          guest: 64Gi
        resources:
          requests:
            memory: 64Gi
        devices:
          disks:
          - name: rootdisk
            disk:
              bus: virtio
          - name: cloudinit
            disk:
              bus: virtio
          interfaces:
          - name: default
            masquerade: {}
          hostDevices:
          - name: gpu-0
            deviceName: nvidia.com/gpu
          - name: gpu-1
            deviceName: nvidia.com/gpu
          - name: gpu-2
            deviceName: nvidia.com/gpu
          - name: gpu-3
            deviceName: nvidia.com/gpu
          - name: gpu-4
            deviceName: nvidia.com/gpu
          - name: gpu-5
            deviceName: nvidia.com/gpu
          - name: gpu-6
            deviceName: nvidia.com/gpu
          - name: gpu-7
            deviceName: nvidia.com/gpu
          - name: nvswitch-0
            deviceName: nvidia.com/nvswitch
          - name: nvswitch-1
            deviceName: nvidia.com/nvswitch
          - name: nvswitch-2
            deviceName: nvidia.com/nvswitch
          - name: nvswitch-3
            deviceName: nvidia.com/nvswitch
      networks:
      - name: default
        pod: {}
      volumes:
      - name: rootdisk
        dataVolume:
          name: ubuntu2404-gpu-vm-gpu03-disk
      - name: cloudinit
        cloudInitNoCloud:
          userData: |
            #cloud-config
            user: ubuntu
            password: ubuntu123
            chpasswd:
              expire: false
            ssh_pwauth: true
            ssh_authorized_keys:
            - <YOUR_SSH_PUBLIC_KEY>
```

```bash
oc apply -f manifests/vm-ubuntu2404-gpu-gpu03.yaml

# Monitor image download
oc get datavolume ubuntu2404-gpu-vm-gpu03-disk -n gpu-vms -w
# Wait for: PHASE=Succeeded  PROGRESS=100.0%

oc get vmi ubuntu2404-gpu-vm-gpu03 -n gpu-vms -w
# Wait for: PHASE=Running  (node should show lp-nvaie-rh-gpu03)
```

### 10.6 SSH and install drivers on the gpu03 VM

```bash
virtctl ssh ubuntu@vm/ubuntu2404-gpu-vm-gpu03/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'
```

Inside the VM, follow the same steps as Part 9.4 (NVIDIA driver, Fabric Manager,
CUDA Toolkit). The procedure is identical — the VM sees the same PCI device IDs
regardless of which physical node it runs on.

---

## Troubleshooting

### Router pods crash-looping / console 503

**Symptom:** `oc get pods -n openshift-ingress` shows the router pod restarting.
Console ClusterOperator shows `DEGRADED=True` with `503 Service Unavailable`.

**Root cause:** The router runs with `hostNetwork: true`. Traffic from host-network
pods destined for the `kubernetes` service ClusterIP (`172.30.0.1:443`) is routed
through OVN's link-local overlay. OVN's reverse-DNAT does not fire for
locally-originated traffic, so the TCP connection never completes.

**Permanent fix:** included in `manifests/99-master-permanent-fixes.yaml` (Part 2.3).

**Manual recovery:**

```bash
ssh core@lp-nvaie-rh-gpu02 'sudo iptables -t nat -I OUTPUT 1 \
  -d 172.30.0.1/32 -p tcp --dport 443 \
  -j DNAT --to-destination 172.16.0.13:6443'

oc delete pod -n openshift-ingress \
  -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default
```

### LVMCluster stuck in Degraded

**Symptom:** `oc get lvmcluster -n openshift-storage` shows `STATUS=Degraded`.
Events mention device has an invalid filesystem signature.

**Fix:** Identify the actual device the VG was created on:

```bash
oc debug node/lp-nvaie-rh-gpu02 -- chroot /host pvs
# Note the PV device — e.g. /dev/nvme4n1

oc patch lvmcluster lvmcluster -n openshift-storage \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/storage/deviceClasses/0/deviceSelector/paths/0","value":"/dev/nvme4n1"}]'
```

### GPU not bound to vfio-pci (nvidia driver wins after reboot)

**Symptom:** After applying the vfio-pci MachineConfig and rebooting, GPUs still show
`Kernel driver in use: nvidia`.

**Most likely cause:** The NVIDIA GPU Operator is installed and its `vfioManager` or
`driver` component is rebinding the GPUs. See Part 2.6 for the fix.

**Verify:**

```bash
oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.spec.driver.enabled} {.spec.vfioManager.enabled}'
# If either shows 'true', apply the fix from Part 2.6
```

### GPU not visible inside VM (lspci shows nothing)

**Check 1 — permittedHostDevices configured:**

```bash
kubectl get hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv -o jsonpath='{.spec.permittedHostDevices}' | python3 -m json.tool
```

**Check 2 — virt-launcher pod has GPU resource:**

```bash
oc describe pod -n gpu-vms -l kubevirt.io=virt-launcher | grep -i "nvidia\|gpu"
```

**Check 3 — GPU is bound to vfio-pci on the host:**

```bash
oc debug node/lp-nvaie-rh-gpu02 -- chroot /host \
  sh -c 'lspci -k | grep -A2 "10de:2330" | grep "Kernel driver"'
# Expected: Kernel driver in use: vfio-pci
```

### PVC stuck in Pending

Usually one of: LVMS Degraded, CDI not fully deployed (Part 5), or source PVC deleted.

```bash
oc get pods -n openshift-cnv | grep cdi

# Remove stuck DataVolume finalizer
oc patch datavolume <name> -n <ns> \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
oc delete pvc <name> -n <ns> --grace-period=0 --force
```

### virtctl ssh — target format error

```
error: target must contain type and name separated by '/'
```

Use `<user>@vm/<name>/<namespace>` format:

```bash
# Correct
virtctl ssh ubuntu@vm/ubuntu2404-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

# Wrong (fails)
virtctl ssh ubuntu@ubuntu2404-gpu-vm -n gpu-vms
```

### nvidia driver not loading at boot after install

After installing `nvidia-open-580` via DKMS, the driver builds successfully but
does not auto-load at boot. Add it explicitly:

```bash
echo nvidia | sudo tee /etc/modules-load.d/nvidia.conf
```

Verify on next boot: `cat /proc/driver/nvidia/version`

### Fabric Manager version mismatch

```
nvidia-fabricmanager: error while loading shared libraries
```

or FM fails to start because of a driver version mismatch. The FM version must
exactly match the installed driver. Ubuntu packages use the `-1ubuntu1` suffix:

```bash
DRIVER_VER=$(cat /proc/driver/nvidia/version | awk '{print $8}')
sudo apt-get install -y nvidia-fabricmanager=${DRIVER_VER}-1ubuntu1
```

---

## Quick Reference

```bash
# Set kubeconfig
export KUBECONFIG=~/.kube/config

# Node and cluster health
oc get nodes
oc get machineconfigpool
oc get clusteroperators | grep -v "True.*False.*False"

# Storage
oc get lvmcluster -n openshift-storage
oc get storageclass
oc get pv

# OpenShift Virtualization
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv
oc get pods -n openshift-cnv | grep -v Running | grep -v Completed

# VMs
oc get vm -A
oc get vmi -A
oc get datavolume -A

# virtctl — Ubuntu VM on gpu02 (SNO node)
virtctl start ubuntu2404-gpu-vm -n gpu-vms
virtctl stop ubuntu2404-gpu-vm -n gpu-vms
virtctl restart ubuntu2404-gpu-vm -n gpu-vms
virtctl ssh ubuntu@vm/ubuntu2404-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'
virtctl ssh ubuntu@vm/ubuntu2404-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' \
  -c '<remote-command>'

# virtctl — Ubuntu VM on gpu03 (worker node)
virtctl start ubuntu2404-gpu-vm-gpu03 -n gpu-vms
virtctl stop ubuntu2404-gpu-vm-gpu03 -n gpu-vms
virtctl restart ubuntu2404-gpu-vm-gpu03 -n gpu-vms
virtctl ssh ubuntu@vm/ubuntu2404-gpu-vm-gpu03/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

# virtctl — RHEL 9 VM
virtctl start rhel9-gpu-vm -n gpu-vms
virtctl stop rhel9-gpu-vm -n gpu-vms
virtctl ssh cloud-user@vm/rhel9-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

# GPU binding check on a node
oc debug node/lp-nvaie-rh-gpu02 -- chroot /host sh -c "
  for dev in \$(lspci -d 10de: -D | awk '{print \$1}'); do
    driver=\$(readlink /sys/bus/pci/devices/\$dev/driver 2>/dev/null | xargs basename 2>/dev/null || echo NONE)
    echo \"\$dev -> \$driver\"
  done"

# Check GPU + NVSwitch capacity on each node
oc describe node lp-nvaie-rh-gpu02 | grep "nvidia.com"
oc describe node lp-nvaie-rh-gpu03 | grep "nvidia.com"

# Check HCO permittedHostDevices (use v1beta1 to see the real stored value)
kubectl get hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv -o jsonpath='{.spec.permittedHostDevices}' | python3 -m json.tool

# Patch HCO permittedHostDevices (always use v1beta1)
kubectl patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv --type=json \
  -p='[{"op":"add","path":"/spec/permittedHostDevices/pciHostDevices/-",
        "value":{"pciDeviceSelector":"10de:22a3","resourceName":"nvidia.com/nvswitch"}}]'

# GPU Operator — disable driver and vfioManager to allow VFIO passthrough
oc patch clusterpolicy gpu-cluster-policy \
  --type=merge -p '{"spec":{"driver":{"enabled":false},"vfioManager":{"enabled":false}}}'

# MCO pause/unpause (freeze cluster during VM workloads)
oc patch machineconfigpool master --type=merge -p '{"spec":{"paused":true}}'
oc patch machineconfigpool master --type=merge -p '{"spec":{"paused":false}}'
oc patch machineconfigpool worker --type=merge -p '{"spec":{"paused":true}}'
oc patch machineconfigpool worker --type=merge -p '{"spec":{"paused":false}}'
```
