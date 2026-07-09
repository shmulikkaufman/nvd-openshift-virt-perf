# SNO + OpenShift Virtualization + GPU Passthrough — Complete Setup Guide

## Overview

This guide covers the full path from bare metal to a running RHEL 9 VM with an NVIDIA
H100 GPU passed through via VFIO on a Single Node OpenShift (SNO) cluster.

**Reference environment:**

| Item | Value |
|------|-------|
| Node hostname | `lp-nvaie-rh-gpu03` |
| OCP version | 4.22 |
| Node OS | RHEL CoreOS 9.8 |
| CPUs / RAM | 112 vCPUs / 252 GB |
| GPUs | 8x NVIDIA H100 SXM5 80GB (`10DE:2330`) |
| Management NIC | `ens12f0np0` → `lp-nvaie-rh-gpu03` |
| OVN NIC | `ens6f0np0` → enslaved into `br-ex` (`172.16.0.213`) |
| Free NVMe | `/dev/nvme0n1` (3.5 TB) — used for LVMS |
| Bastion/launchpad | `global.prd.ga.launchpad.nvidia.com:13561` as user `nvidia` |
| SNO kubeconfig | `/home/nvidia/sno/kubeconfig` on the bastion |

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
| `ens12f0np0` | Management (kubelet, API, etcd, SSH) | `lp-nvaie-rh-gpu03` |
| `ens6f0np0` | OVN external bridge (`br-ex`) | `172.16.0.213` (SNAT source) |

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
- hostname: lp-nvaie-rh-gpu03
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
export KUBECONFIG=~/sno/install-dir/auth/kubeconfig

# Verify node is Ready
oc get nodes

# Copy kubeconfig to the bastion home for convenience
cp ~/sno/install-dir/auth/kubeconfig ~/sno/kubeconfig
```

SSH to the node:

```bash
ssh -i ~/.ssh/id_rsa core@lp-nvaie-rh-gpu03
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
export KUBECONFIG=/home/nvidia/sno/kubeconfig
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

### 2.5 Apply MachineConfig: bind GPUs to vfio-pci

This unbinds the NVIDIA driver from the GPUs at boot and binds `vfio-pci` instead,
making the GPU available for VFIO passthrough. QEMU/KVM will present the physical
PCIe device directly to the guest VM.

The two files written to the node:

| File | Content |
|------|---------|
| `/etc/modprobe.d/vfio.conf` | `softdep nvidia pre: vfio-pci` + `options vfio-pci ids=10de:2330` |
| `/etc/modules-load.d/vfio-pci.conf` | `vfio-pci` |

Compute the base64 values:

```bash
# vfio.conf — adjust ids= for your GPU PCI device ID
printf 'softdep nvidia pre: vfio-pci\noptions vfio-pci ids=10de:2330\n' | base64 -w0
# → c29mdGRlcCBudmlkaWEgcHJlOiB2ZmlvLXBjaQpvcHRpb25zIHZmaW8tcGNpIGlkcz0xMGRlOjIzMzAK

printf 'vfio-pci\n' | base64 -w0
# → dmZpby1wY2kK
```

Apply:

**`manifests/100-master-vfio-pci-gpu.yaml`:**

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
          # "softdep nvidia pre: vfio-pci\noptions vfio-pci ids=10de:2330\n"
          source: "data:text/plain;charset=utf-8;base64,c29mdGRlcCBudmlkaWEgcHJlOiB2ZmlvLXBjaQpvcHRpb25zIHZmaW8tcGNpIGlkcz0xMGRlOjIzMzAK"
      - path: /etc/modules-load.d/vfio-pci.conf
        mode: 0644
        contents:
          source: "data:text/plain;charset=utf-8;base64,dmZpby1wY2kK"
```

```bash
oc apply -f manifests/100-master-vfio-pci-gpu.yaml
```

### 2.6 Wait for MCO to apply all MachineConfigs

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
# kubelet node-ip override
ssh core@lp-nvaie-rh-gpu03 'cat /etc/systemd/system/kubelet.service.d/21-node-ip-override.conf'
# Expected: Environment="KUBELET_NODE_IP=172.16.0.13" "KUBELET_NODE_IPS=172.16.0.13"

# IOMMU in kernel args
ssh core@lp-nvaie-rh-gpu03 'cat /proc/cmdline | grep -o "iommu[^ ]*\|intel_iommu[^ ]*"'
# Expected: intel_iommu=on  iommu=pt

# GPUs bound to vfio-pci
ssh core@lp-nvaie-rh-gpu03 'lspci -k | grep -A2 "10de:2330" | grep "Kernel driver"'
# Expected: Kernel driver in use: vfio-pci

# Node advertises GPUs
oc describe node lp-nvaie-rh-gpu03 | grep "nvidia.com/gpu"
# Expected: nvidia.com/gpu: 8
```

---

## Part 3 — Storage (LVMS)

VMs need persistent block storage. LVMS (LVM Storage) provisions thin-provisioned
LVM volumes from bare NVMe disks and exposes them as a `topolvm.io` StorageClass.

### 3.1 Identify the free disk

```bash
ssh core@lp-nvaie-rh-gpu03 'lsblk -o NAME,SIZE,TYPE,MOUNTPOINT'
```

The OS disk will have partitions with `/sysroot` or `/boot` mountpoints. All other
disks are candidates. In this environment, `/dev/nvme0n1` (3.5 TB) is free.

> **Warning:** LVMS will fail if the disk has any existing filesystem signature
> (including `linux_raid_member`, `xfs`, `ext4`). Wipe it first:
>
> ```bash
> ssh core@lp-nvaie-rh-gpu03 'sudo wipefs -a /dev/nvme0n1'
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
# Wait for: lvms-operator-* Running
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
        - /dev/nvme0n1
      thinPoolConfig:
        name: thin-pool
        sizePercent: 90
        overprovisionRatio: 10
      fstype: xfs
```

> Adjust `deviceSelector.paths` to your free disk. Verify with `ssh core@lp-nvaie-rh-gpu03 'lsblk'`.

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
a running pod.

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

### 4.4 Configure GPU passthrough (permittedHostDevices)

Get the PCI IDs of your GPUs:

```bash
ssh core@lp-nvaie-rh-gpu03 'lspci -nn | grep -i nvidia'
# Example output:
# 52:00.0 3D controller [0302]: NVIDIA Corporation GH100 [H100 SXM5 80GB] [10de:2330] (rev a1)
```

The PCI device ID is the last 4-digit hex value in brackets — `2330` for H100 SXM5.

Patch HyperConverged to allow VMs to use the GPU:

```bash
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  --type=json \
  -p='[{
    "op": "add",
    "path": "/spec/permittedHostDevices",
    "value": {
      "pciHostDevices": [{
        "pciDeviceSelector": "10de:2330",
        "resourceName": "nvidia.com/gpu"
      }]
    }
  }]'
```

Verify:

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.permittedHostDevices}' && echo ""
# Expected: {"pciHostDevices":[{"pciDeviceSelector":"10de:2330","resourceName":"nvidia.com/gpu"}]}

# Node should advertise GPUs as allocatable
oc describe node lp-nvaie-rh-gpu03 | grep "nvidia.com/gpu"
# Expected: nvidia.com/gpu: 8  (twice — capacity and allocatable)
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

# All CDI CRDs now registered:
oc get crd | grep cdi
# Expected: datavolumes.cdi.kubevirt.io, datasources.cdi.kubevirt.io, etc.
```

---

## Part 6 — Create a GPU VM

### 6.1 Create the VM namespace

```bash
oc new-project gpu-vms
```

### 6.2 Prepare registry credentials for CDI

CDI needs access to `registry.redhat.io` to import the RHEL 9 guest image.
The cluster pull-secret has these credentials; extract and place them in the
namespace where CDI performs the import:

```bash
# Extract username and password for registry.redhat.io from the cluster pull-secret
oc get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | \
  python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
auth = d['auths']['registry.redhat.io']['auth']
user, pw = base64.b64decode(auth).decode().split(':', 1)
print(f'USER={user}')
print(f'PW_LEN={len(pw)}')"

# Store user/pw in variables (run the python block, then assign manually or pipe)
eval "$(oc get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | \
  python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
auth = d['auths']['registry.redhat.io']['auth']
user, pw = base64.b64decode(auth).decode().split(':', 1)
print(f'RH_USER={user}')
print(f'RH_PW={pw}')")"

# Create CDI-format secret (Opaque with accessKeyId / secretKey)
oc create secret generic redhat-registry-pull-secret \
  -n openshift-virtualization-os-images \
  --from-literal=accessKeyId="$RH_USER" \
  --from-literal=secretKey="$RH_PW"
```

### 6.3 Import the RHEL 9 golden image

CDI will pull the RHEL 9 guest container disk from the Red Hat registry and write
the raw disk image to an LVM block volume. This takes ~1–2 minutes depending on
network speed.

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

> To find the latest RHEL 9 guest image digest:
> ```bash
> oc get imagestream rhel9-guest -n openshift-virtualization-os-images \
>   -o jsonpath='{.status.tags[0].items[0].image}'
> ```

```bash
oc apply -f manifests/dv-rhel9-golden.yaml

# Watch import progress
oc get datavolume rhel9-guest -n openshift-virtualization-os-images -w
# Wait for: PHASE=Succeeded  PROGRESS=100.0%
```

To find the latest RHEL 9 guest image digest:

```bash
oc get imagestream rhel9-guest -n openshift-virtualization-os-images \
  -o jsonpath='{.status.tags[0].items[0].image}'
```

### 6.4 Create the VirtualMachine

The VM uses `dataVolumeTemplates` to automatically clone the golden image disk
when the VM CR is created. All 8 GPUs and 4 NVSwitches are requested via `hostDevices`
referencing the `resourceName` values configured in `permittedHostDevices`.

Before applying, edit `manifests/vm-rhel9-gpu.yaml` and replace `<YOUR_SSH_PUBLIC_KEY>`
with your actual public key (e.g. the contents of `~/.ssh/id_rsa.pub`).

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
# Watch DataVolume clone (sourced from the golden image)
oc get datavolume rhel9-gpu-vm-disk -n gpu-vms -w
# Wait for: PHASE=Succeeded  PROGRESS=100.0%  (~60-90s)

# Watch VMI come up
oc get vmi rhel9-gpu-vm -n gpu-vms -w
# Wait for: PHASE=Running

# Get VM IP address
oc get vmi rhel9-gpu-vm -n gpu-vms \
  -o jsonpath='{.status.interfaces[0].ipAddress}' && echo ""
```

### 6.6 Verify GPU inside the VM

```bash
# SSH into the VM via virtctl (uses Kubernetes API — no direct route needed)
virtctl ssh cloud-user@vmi/rhel9-gpu-vm -n gpu-vms \
  --identity-file ~/.ssh/id_rsa \
  --local-ssh-opts="-o StrictHostKeyChecking=no" \
  --command "lspci | grep -i nvidia"

# Expected output:
# 09:00.0 3D controller: NVIDIA Corporation GH100 [H100 SXM5 80GB] (rev a1)
```

The GPU is visible as a PCI device. NVIDIA drivers are not yet installed in the
guest; see Part 7 for driver installation.

### 6.7 Add more GPU VMs

Each additional VM uses one GPU from the pool. To add a second GPU VM, repeat
Step 6.4 with a different name (e.g. `rhel9-gpu-vm-2`). The golden image is
already in place; only a new clone + new VM CR is needed.

```bash
# Check remaining GPU allocation
oc describe node lp-nvaie-rh-gpu03 | grep -A4 "Allocated resources"
# nvidia.com/gpu  1  1   (1 in use, 7 still free)
```

---

## Part 7 — Install NVIDIA Drivers in the Guest VM

### 7.1 Open an SSH session into the VM

```bash
virtctl ssh cloud-user@vmi/rhel9-gpu-vm -n gpu-vms \
  --identity-file ~/.ssh/id_rsa \
  --local-ssh-opts="-o StrictHostKeyChecking=no"
```

### 7.2 Enable RHEL repos using cluster entitlement certs

The RHEL 9 guest image ships with no repos enabled. The cluster's own entitlement
certificates (stored as a Kubernetes secret) can authenticate to Red Hat CDN
without a separate subscription registration.

On the **bastion**, extract the certs and copy them into the VM:

```bash
export KUBECONFIG=/home/nvidia/sno/kubeconfig

oc get secret etc-pki-entitlement -n openshift-config-managed \
  -o jsonpath='{.data.entitlement\.pem}' | base64 -d > /tmp/entitlement.pem

oc get secret etc-pki-entitlement -n openshift-config-managed \
  -o jsonpath='{.data.entitlement-key\.pem}' | base64 -d > /tmp/entitlement-key.pem

virtctl scp /tmp/entitlement.pem \
  cloud-user@vmi/rhel9-gpu-vm:/tmp/ -n gpu-vms --identity-file ~/.ssh/id_rsa

virtctl scp /tmp/entitlement-key.pem \
  cloud-user@vmi/rhel9-gpu-vm:/tmp/ -n gpu-vms --identity-file ~/.ssh/id_rsa
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
# Expected: rhel-9-baseos, rhel-9-appstream, rhel-9-crb
```

### 7.3 Add EPEL and the NVIDIA CUDA repo

```bash
# EPEL provides dkms
sudo dnf install -y \
  https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# NVIDIA CUDA repo
sudo dnf config-manager --add-repo \
  https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo

sudo dnf makecache
```

### 7.4 Install build tools and NVIDIA open kernel modules

H100 (Hopper/GH100) requires the **open** kernel modules — the proprietary
`nvidia` module does not support GH100 and later GPUs.

```bash
sudo dnf install -y \
  kernel-devel-$(uname -r) \
  kernel-headers-$(uname -r) \
  gcc make dkms \
  nvidia-open \
  nvidia-driver-cuda

sudo reboot
```

`nvidia-open` is a meta-package that pulls in `kmod-nvidia-open-dkms`, which
builds the open-source NVIDIA kernel modules against the running kernel via DKMS.

### 7.5 Verify

After reboot, SSH back in and run:

```bash
nvidia-smi
```

Expected output:

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 610.43.02              KMD Version: 610.43.02     CUDA UMD Version: 13.3     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA H100 80GB HBM3          On  |   00000000:09:00.0 Off |                    0 |
| N/A   31C    P0             70W /  700W |       0MiB /  81559MiB |      0%      Default |
|                                         |                        |             Disabled |
+-----------------------------------------+------------------------+----------------------+
```

### 7.6 Create and compile the CUDA smoke test

`gpu_test.cu` is a small self-contained CUDA program that does two things:

**Phase 1 — Device enumeration.** For each visible GPU it calls
`cudaGetDeviceProperties` and `cudaMemGetInfo` to print the GPU name, compute
capability, number of Streaming Multiprocessors (SMs), total and free HBM memory,
ECC status, and which peer GPUs can do direct NVLink transfers to this one.
The peer-access query (`cudaDeviceCanAccessPeer`) is what implicitly exercises the
Fabric Manager code path — FM must have initialized the NVLink fabric before this
returns successfully.

**Phase 2 — Memory-bandwidth smoke test.** Allocates three arrays of 16 million
`float`s (64 MB each) in GPU HBM:

- `a[i] = 1.0`, `b[i] = 2.0` filled on the host and copied to the GPU.
- A CUDA kernel runs `c[i] = a[i] + b[i]` across all 16M elements using
  65,537 blocks × 256 threads, fully saturating the SM grid.
- The kernel is timed with CUDA events (GPU-side hardware timer — no PCIe or host
  overhead in the measurement).
- Effective HBM bandwidth is calculated as `3 × 64 MB / kernel_time_s`
  (2 reads + 1 write per element).
- The result is copied back to the host and every element is checked against 3.0.
  Any mismatch is counted and reported. Exit code is 0 on PASS, 1 on FAIL.

The program is compiled with `nvcc`. Note: CUDA 13.3 removed `cudaDeviceProp::clockRate`
and `cudaDeviceProp::memoryClockRate` — do not reference those fields.

```bash
# Copy gpu_test.cu into the VM (run from bastion)
virtctl scp gpu_test.cu cloud-user@vm/rhel9-gpu-vm/gpu-vms:/home/cloud-user/ \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

# Compile inside the VM
virtctl ssh cloud-user@vm/rhel9-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' \
  -c 'export PATH=/usr/local/cuda/bin:$PATH; nvcc -O2 -o gpu_test gpu_test.cu && echo "Compiled OK"'
```

The source (`gpu_test.cu`):

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

### 7.7 CUDA API Explorer (interactive menu tool)

`cuda_menu.cu` is a larger interactive tool that lets you exercise 14 CUDA API
categories individually from a numbered menu. Useful both for verifying that specific
APIs work correctly and for learning what each one does by reading its annotated output.

```bash
# Copy, compile, run
virtctl scp /path/to/cuda_menu.cu cloud-user@vm/rhel9-gpu-vm/gpu-vms:/home/cloud-user/ \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

virtctl ssh cloud-user@vm/rhel9-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' \
  -c 'export PATH=/usr/local/cuda/bin:$PATH; nvcc -O2 -o cuda_menu cuda_menu.cu'

# Run interactively (requires a real TTY — use virtctl console or direct SSH)
virtctl ssh cloud-user@vm/rhel9-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'
# then: export PATH=/usr/local/cuda/bin:$PATH && ./cuda_menu
```

**Menu items:**

| # | Item | Key APIs |
|---|------|----------|
| 1 | GPU discovery & basic info | `cudaGetDeviceCount`, `cudaGetDeviceProperties` |
| 2 | Full device properties | All `cudaDeviceProp` fields grouped by category |
| 3 | Memory info & limits | `cudaMemGetInfo` (live free/used HBM) |
| 4 | Driver & runtime versions | `cudaDriverGetVersion`, `cudaRuntimeGetVersion` |
| 5 | Memory allocation types | `cudaMalloc`, `cudaMallocHost`, `cudaMallocManaged`, `cudaPointerGetAttributes` |
| 6 | HBM bandwidth sweep | Measures bandwidth at 1–512 MiB to show L2 vs HBM crossover |
| 7 | Kernel timing with events | Step-by-step `cudaEventRecord` / `cudaEventElapsedTime` walkthrough |
| 8 | Concurrent streams | Multi-stream vs serial kernel launch timing |
| 9 | Peer access & NVLink topology | `cudaDeviceCanAccessPeer`, `cudaDeviceGetP2PAttribute` |
| 10 | P2P copy bandwidth | `cudaMemcpyPeerAsync` between GPU pairs |
| 11 | Kernel occupancy | `cudaOccupancyMaxActiveBlocksPerMultiprocessor`, `cudaOccupancyMaxPotentialBlockSize` |
| 12 | Async memcpy pipeline | `cudaMallocHost` + `cudaMemcpyAsync` overlap demo |
| 13 | CUDA graphs — capture & replay | `cudaStreamBeginCapture`, `cudaGraphInstantiate`, `cudaGraphLaunch` |
| 14 | Error handling | `cudaGetLastError`, `cudaPeekAtLastError`, error code table |

**Sample output for H100 SXM5 (selected items):**

```
# Item 6 — HBM bandwidth sweep
  Size          Time(ms)     BW (GB/s)  Note
  1                0.004         805.4  <= L2, L2-bound
  64               0.076        2656.4  > L2, HBM-bound
  512              0.580        2776.3  > L2, HBM-bound
  (L2 crossover at 50 MiB — H100 L2 cache size)

# Item 11 — occupancy (H100: 2048 threads/SM max)
  Block size    Active blks/SM  Occupancy
  32            32              50.0%
  64            32              100.0%   ← minimum for full occupancy

# Item 13 — CUDA graphs
  200 iterations of 3-kernel sequence:
    cudaGraphLaunch : 0.0508 ms/iter
    Stream launch   : 0.0549 ms/iter    (graphs remove per-kernel launch overhead)
```

---

## Troubleshooting

### Router pods crash-looping / console 503

**Symptom:** `oc get pods -n openshift-ingress` shows the router pod restarting.
Router logs show `backend-http has-synced=false` repeatedly. Console ClusterOperator
shows `DEGRADED=True` with `503 Service Unavailable`.

**Root cause:** The router runs with `hostNetwork: true`. Traffic from host-network
pods destined for the `kubernetes` service ClusterIP (`172.30.0.1:443`) is routed
through OVN's link-local overlay (`via 169.254.0.4 dev br-ex`). OVN's reverse-DNAT
does not fire for locally-originated traffic, so the TCP connection never completes
and the router cannot sync routes from the API server.

Specifically:
- `ip route get 172.30.0.1` → `via 169.254.0.4 dev br-ex src 169.254.0.2`
- `curl -sk https://172.30.0.1:443/healthz` → hangs (no response)
- `curl -sk https://lp-nvaie-rh-gpu03:6443/healthz` → `ok` (direct API path works)

The kubelet node-IP fix (`99-master-permanent-fixes`) correctly binds kubelet to
`lp-nvaie-rh-gpu03`. That alone is not sufficient — the iptables DNAT shortcut is also needed.

**Permanent fix (included in `manifests/99-master-permanent-fixes.yaml`, applied in Part 2.3):**

The `sno-iptables-fix.service` systemd unit runs at boot and inserts the rule:

```bash
# Applied by sno-iptables-fix.service on every boot
iptables -t nat -I OUTPUT 1 \
  -d 172.30.0.1/32 -p tcp --dport 443 \
  -j DNAT --to-destination 172.16.0.13:6443
```

This intercepts OUTPUT traffic before OVN routing so the kernel handles DNAT
reversal correctly. Verify the service ran:

```bash
ssh core@lp-nvaie-rh-gpu03 'systemctl status sno-iptables-fix.service'
# Expected: Active: active (exited) ... status=0/SUCCESS

ssh core@lp-nvaie-rh-gpu03 'sudo iptables -t nat -L OUTPUT -n | grep DNAT'
# Expected: DNAT tcp -- 0.0.0.0/0 172.30.0.1 tcp dpt:443 to:172.16.0.13:6443
```

**Manual recovery (if the console goes 503 and the service hasn't run):**

```bash
# 1. Apply the iptables rule immediately
ssh core@lp-nvaie-rh-gpu03 'sudo iptables -t nat -I OUTPUT 1 \
  -d 172.30.0.1/32 -p tcp --dport 443 \
  -j DNAT --to-destination 172.16.0.13:6443'

# 2. Verify the kubernetes service is now reachable from the host
ssh core@lp-nvaie-rh-gpu03 'curl -sk https://172.30.0.1:443/healthz && echo'
# Expected: ok

# 3. Delete the crashing router pod to force a clean restart
oc delete pod -n openshift-ingress \
  -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default

# 4. Wait ~30s and confirm router is 1/1 Running
oc get pods -n openshift-ingress
oc get clusteroperator console
```

### LVMCluster stuck in Degraded

**Symptom:** `oc get lvmcluster -n openshift-storage` shows `STATUS=Degraded`.
Events mention `mandatory device path "/dev/nvmeXn1" cannot be used` with reason
`has an invalid filesystem signature (linux_raid_member)`.

**Cause:** The device path in the LVMCluster spec points to a disk that is part
of an MD RAID array or has an existing filesystem. This can also happen after a
reboot if NVMe device numbers shift (e.g. `nvme4n1` becomes `nvme0n1`).

**Fix:** Identify the actual device the VG was created on and patch the spec:

```bash
ssh core@lp-nvaie-rh-gpu03 'sudo pvs'
# Note the PV device — e.g. /dev/nvme0n1

oc patch lvmcluster lvmcluster -n openshift-storage \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/storage/deviceClasses/0/deviceSelector/paths/0","value":"/dev/nvme0n1"}]'

oc get lvmcluster -n openshift-storage
# Expected: STATUS=Ready  (within ~30s)
```

### PVC stuck in Pending (DataVolume CloneInProgress for hours)

**Symptom:** `oc get datavolume -n <ns>` shows `PHASE=CloneInProgress` for more
than 10 minutes with no progress. The PVC remains `Pending`.

**Root cause:** Usually one of:
1. LVMS is Degraded (fix with the patch above)
2. CDI is not fully deployed (check for orphaned ConfigMap — see Part 5)
3. The source PVC for the clone was deleted before the clone completed

**Fix:**

```bash
# Check CDI pods
oc get pods -n openshift-cnv | grep cdi

# If only cdi-operator is present, apply the CDI orphan fix (Part 5)

# Remove the stuck DataVolume finalizer and delete it
oc patch datavolume <name> -n <ns> \
  --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'
oc delete pvc <name> -n <ns> --grace-period=0 --force

# Recreate the DataVolume fresh once CDI is healthy
```

### CDI importer pod — secret not found

**Symptom:** CDI importer pod stays in `CreateContainerConfigError`. Pod events show:

```
Error: secret "redhat-registry-pull-secret" not found
```

**Cause:** The registry secret was created with type `kubernetes.io/dockerconfigjson`
but CDI expects type `Opaque` with keys `accessKeyId` and `secretKey`.

**Fix:** Delete and recreate with the Opaque format (see Part 6.2).

### virtctl ssh — host key verification failed

After restarting a VM, the SSH host key changes (new VM instance). Remove the old
known_hosts entry:

```bash
ssh-keygen -f ~/.ssh/known_hosts -R vmi.rhel9-gpu-vm.gpu-vms
```

### GPU not visible inside VM (lspci shows nothing)

**Check 1 — permittedHostDevices configured:**

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.permittedHostDevices}' && echo ""
```

**Check 2 — virt-launcher pod has GPU resource:**

```bash
oc describe pod -n gpu-vms -l kubevirt.io=virt-launcher | grep -i "nvidia\|gpu"
# Expected: Limits: nvidia.com/gpu: 1
```

**Check 3 — QEMU is using vfio-pci:**

```bash
ssh core@lp-nvaie-rh-gpu03 'ps aux | grep qemu | grep -o "vfio-pci[^}]*"'
# Expected: vfio-pci","host":"XXXX:XX:XX.X",...
```

**Check 4 — GPU is bound to vfio-pci on the host:**

```bash
ssh core@lp-nvaie-rh-gpu03 'lspci -k | grep -A2 "10de:2330" | grep "Kernel driver"'
# Expected: Kernel driver in use: vfio-pci
```

If the GPU is bound to the `nvidia` driver instead of `vfio-pci`, the
`100-master-vfio-pci-gpu` MachineConfig has not been applied. Verify:

```bash
oc get machineconfig 100-master-vfio-pci-gpu
oc get machineconfigpool master
```

---

## Part 8 — NVSwitch Passthrough and NVIDIA Fabric Manager

H100 SXM5 GPUs are physically connected to NVSwitches via NVLink. Without NVSwitch
hardware accessible to the VM, CUDA returns `CUDA_ERROR_SYSTEM_NOT_READY` (error 802)
because `cuInit()` waits for the NVIDIA Fabric Manager, which requires NVSwitch access.

This part passes all 4 NVSwitches to the VM and starts Fabric Manager inside the guest.

### 8.1 Find NVSwitch PCI IDs and IOMMU groups

```bash
ssh core@lp-nvaie-rh-gpu03 'lspci -nn | grep -i nvswitch'
# Example output:
# 07:00.0 Bridge [0604]: NVIDIA Corporation GH100 [H100 NVSwitch] [10de:22a3] (rev a1)
# 08:00.0 Bridge [0604]: NVIDIA Corporation GH100 [H100 NVSwitch] [10de:22a3] (rev a1)
# 09:00.0 Bridge [0604]: NVIDIA Corporation GH100 [H100 NVSwitch] [10de:22a3] (rev a1)
# 0a:00.0 Bridge [0604]: NVIDIA Corporation GH100 [H100 NVSwitch] [10de:22a3] (rev a1)

# Check IOMMU groups — each NVSwitch must be in its own group (single device per group)
for bdf in 07:00.0 08:00.0 09:00.0 0a:00.0; do
  group=$(readlink /sys/bus/pci/devices/0000:${bdf}/iommu_group | awk -F/ '{print $NF}')
  echo "NVSwitch $bdf -> IOMMU group $group"
  ls /sys/kernel/iommu_groups/${group}/devices/
done
```

### 8.2 Bind NVSwitches to vfio-pci via MachineConfig

Update the existing GPU MachineConfig to also include the NVSwitch PCI ID (`10de:22a3`):

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

# Wait for MCO to apply (triggers node reboot — takes ~5 minutes)
oc wait machineconfigpool master --for=condition=Updated --timeout=600s

# Verify NVSwitches are bound to vfio-pci
ssh core@lp-nvaie-rh-gpu03 'lspci -k | grep -A2 "10de:22a3" | grep "Kernel driver"'
# Expected: Kernel driver in use: vfio-pci
```

### 8.3 Expose NVSwitches in KubeVirt via HyperConverged

The HyperConverged CR (HCO) has two API versions. The `v1` version prunes
`permittedHostDevices`; the `v1beta1` version (the storage version) has the
full schema. Always patch using `v1beta1`:

```bash
# Add NVSwitch to HCO permittedHostDevices (uses v1beta1 API)
kubectl patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv --type=json \
  -p='[{"op":"add","path":"/spec/permittedHostDevices/pciHostDevices/-",
        "value":{"pciDeviceSelector":"10de:22a3","resourceName":"nvidia.com/nvswitch"}}]'

# Verify HCO stored the entry (will be reconciled into KubeVirt within ~10s)
kubectl get hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv -o jsonpath='{.spec.permittedHostDevices}' | python3 -m json.tool

# Verify KubeVirt CR has the entry
oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.configuration.permittedHostDevices}' | python3 -m json.tool

# Verify node reports NVSwitch capacity (may take up to 60s for device plugin)
oc get node -o jsonpath='{.items[0].status.capacity}' | python3 -m json.tool | grep nvidia
# Expected:
#   "nvidia.com/gpu": "8",
#   "nvidia.com/nvswitch": "4",
```

> **Important — use `v1beta1`:** Patching via the default `v1` API silently prunes
> `permittedHostDevices` because the v1 CRD schema does not define the field.
> The storage version is `v1beta1`. Use `kubectl patch hyperconverged.v1beta1.hco.kubevirt.io`
> (not `oc patch hyperconverged`).

> **Note on `externalResourceProvider`:** Do NOT set `externalResourceProvider: true`
> for NVSwitches. That flag signals KubeVirt that an external device plugin manages
> the resource, causing virt-handler to skip it entirely (node reports 0 devices).

### 8.4 Add NVSwitches to the VM spec

```bash
oc patch vm rhel9-gpu-vm -n gpu-vms --type=json -p='[
  {"op":"add","path":"/spec/template/spec/domain/devices/hostDevices/-",
   "value":{"deviceName":"nvidia.com/nvswitch","name":"nvswitch-0"}},
  {"op":"add","path":"/spec/template/spec/domain/devices/hostDevices/-",
   "value":{"deviceName":"nvidia.com/nvswitch","name":"nvswitch-1"}},
  {"op":"add","path":"/spec/template/spec/domain/devices/hostDevices/-",
   "value":{"deviceName":"nvidia.com/nvswitch","name":"nvswitch-2"}},
  {"op":"add","path":"/spec/template/spec/domain/devices/hostDevices/-",
   "value":{"deviceName":"nvidia.com/nvswitch","name":"nvswitch-3"}}
]'

# Restart VM so it picks up the new spec
virtctl restart rhel9-gpu-vm -n gpu-vms

# Wait for VM to be Running
oc get vmi rhel9-gpu-vm -n gpu-vms -w

# Verify all 5 devices are in the VMI spec (1 GPU + 4 NVSwitches)
oc get vmi rhel9-gpu-vm -n gpu-vms \
  -o jsonpath='{.spec.domain.devices.hostDevices}' | python3 -m json.tool
```

### 8.5 Verify NVSwitches and Fabric Manager inside the VM

```bash
virtctl ssh cloud-user@vm/rhel9-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' \
  -c 'lspci | grep -iE "nvidia|3d|bridge"'
# Expected: 1x 3D controller (GPU) + 4x Bridge (NVSwitches)

# Check Fabric Manager status (installed with nvidia-fabricmanager package)
virtctl ssh cloud-user@vm/rhel9-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' \
  -c 'sudo systemctl status nvidia-fabricmanager'
# Expected: Active: active (running)
# Log lines: "Connected to 1 node."
#            "Successfully configured all the available NVSwitches..."
```

Fabric Manager starts automatically on boot once `nvidia-fabricmanager` is installed
and enabled (handled by the `nvidia-driver` package install in Part 7).

### 8.6 Run CUDA test

See Part 7.6 for the full source code and explanation of what the program does.

```bash
virtctl ssh cloud-user@vm/rhel9-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' \
  -c 'export PATH=/usr/local/cuda/bin:$PATH; cd ~; ./gpu_test'
```

Expected output:

```
Found 1 GPU(s)

=== GPU 0: NVIDIA H100 80GB HBM3 ===
  Compute capability : 9.0
  SMs                : 132
  Memory (GiB)       : 79.2 total, 78.7 free
  ECC enabled        : yes
  Peer access        : none

=== Vector addition: 16M floats ===
  Kernel time  : 21.781 ms
  Bandwidth    : 9.2 GB/s
  Errors       : 0
  Result       : PASS
```

What each line confirms:

| Output | What it proves |
|--------|---------------|
| `Found 1 GPU(s)` | CUDA runtime initialised — `cuInit()` succeeded (no error 802) |
| `Compute capability : 9.0` | H100/Hopper architecture correctly identified |
| `SMs : 132` | Full H100 SXM5 die visible (not a MIG slice) |
| `Memory (GiB) : 79.2` | All 80 GB HBM3 accessible |
| `ECC enabled : yes` | Data-centre ECC active |
| `Peer access : none` | Expected with a single GPU in the VM |
| `Errors : 0 / PASS` | GPU compute and HBM memory are error-free |

`Bandwidth` reflects effective HBM throughput for this workload. With a single VM and
one GPU, the value is lower than bare-metal peak because the small 192 MB working set
and VFIO context setup keep it well below the H100's 3.35 TB/s maximum.

### 8.7 Troubleshooting NVSwitch passthrough

#### `cuInit` returns error 802 (`CUDA_ERROR_SYSTEM_NOT_READY`)

This means NVIDIA Fabric Manager is not running or failed to configure the NVSwitches.

```bash
# Check FM service
sudo systemctl status nvidia-fabricmanager

# Check FM logs
sudo journalctl -u nvidia-fabricmanager --no-pager -n 50

# Restart FM
sudo systemctl restart nvidia-fabricmanager
```

FM requires `/dev/nvidia-nvswitch*` devices to be present. These appear automatically
when the NVIDIA driver detects NVSwitch PCI devices. If they are missing:

```bash
lspci | grep -i nvswitch    # NVSwitches must be visible
ls /dev/nvidia-nvswitch*    # Device nodes must exist
```

#### HCO removes NVSwitch from KubeVirt within 1 second

This happens when patching via the default `v1` API (which prunes `permittedHostDevices`).
The fix is to patch via `v1beta1` as shown in step 8.3.

To diagnose, check whether the HCO CR actually stored the entry:

```bash
kubectl get hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv -o jsonpath='{.spec.permittedHostDevices}'
```

If the entry is missing from the HCO CR (but was added to KubeVirt directly), HCO will
reconcile it away on every sync cycle. Always set it in the HCO CR via `v1beta1`.

#### Node reports `nvidia.com/nvswitch: 0`

With `externalResourceProvider: true` set, virt-handler skips the device. Remove it:

```bash
kubectl patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv --type=json \
  -p='[{"op":"replace","path":"/spec/permittedHostDevices/pciHostDevices/1",
        "value":{"pciDeviceSelector":"10de:22a3","resourceName":"nvidia.com/nvswitch"}}]'
```

(Adjust the array index if GPU is not at index 0.)

---

## Part 9 — Ubuntu 24.04 LTS GPU VM on the Second Node

A second identical bare metal node provides its own 8 GPUs and 4 NVSwitches, letting
the Ubuntu VM run alongside the RHEL 9 VM without sharing devices.

### 9.1 Add the second node and label it

After the node joins the cluster as a worker and shows `Ready`:

```bash
# Verify the node is Ready
oc get nodes

# Label it so the Ubuntu VM nodeSelector can find it
kubectl label node <node2-hostname> gpu-vm-node=2
```

### 9.2 Apply worker MachineConfigs for IOMMU and vfio-pci

The master MachineConfigs from Part 2 target `role: master` and only apply to node 1.
Node 2 (worker role) needs its own equivalent configs.

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

# Wait for worker MCO to apply (triggers node 2 reboot)
oc wait machineconfigpool worker --for=condition=Updated --timeout=600s

# Verify on node 2
ssh core@<node2-ip> 'lspci -k | grep -A2 "10de:2330\|10de:22a3" | grep "Kernel driver"'
# Expected: Kernel driver in use: vfio-pci  (for all GPUs and NVSwitches)

# Verify node 2 advertises GPU and NVSwitch capacity
oc describe node <node2-hostname> | grep "nvidia.com"
# Expected:
#   nvidia.com/gpu:     8
#   nvidia.com/nvswitch: 4
```

### 9.3 Create the Ubuntu 24.04 VM

The VM imports Ubuntu 24.04 Noble directly from the Ubuntu cloud image archive.
Storage uses `lvms-vmstorage` (WaitForFirstConsumer) so the 80 GiB PVC binds to
node 2's LVMS when the VM first schedules there. The `nodeSelector` guarantees
scheduling on node 2.

Before applying, replace `<YOUR_SSH_PUBLIC_KEY>` in `manifests/vm-ubuntu2404-gpu.yaml`
with your actual public key.

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
        storageClassName: lvms-vmstorage
        accessModes:
        - ReadWriteOnce
        volumeMode: Block
  template:
    metadata:
      labels:
        kubevirt.io/vm: ubuntu2404-gpu-vm
    spec:
      architecture: amd64
      nodeSelector:
        gpu-vm-node: "2"
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

# Monitor image download (~600 MB compressed, expands to ~3.5 GB)
oc get datavolume ubuntu2404-gpu-vm-disk -n gpu-vms -w
# Wait for: PHASE=Succeeded  PROGRESS=100.0%

# Watch VM come up
oc get vmi ubuntu2404-gpu-vm -n gpu-vms -w
# Wait for: PHASE=Running
```

### 9.4 SSH into the Ubuntu VM

```bash
virtctl ssh ubuntu@vm/ubuntu2404-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'
```

### 9.5 Install NVIDIA open kernel modules and CUDA on Ubuntu 24.04

H100 (Hopper/GH100) requires the open kernel modules. Ubuntu 24.04 uses `apt`
with the NVIDIA CUDA network repository.

```bash
# Add NVIDIA CUDA repository
curl -fsSL \
  https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
  -o /tmp/cuda-keyring.deb
sudo dpkg -i /tmp/cuda-keyring.deb
sudo apt-get update

# Install NVIDIA open kernel modules + CUDA toolkit
sudo apt-get install -y nvidia-open cuda-toolkit

# Determine installed driver version, then install matching Fabric Manager
DRIVER_VER=$(dpkg -l 'nvidia-open-*' | awk '/^ii/{print $2}' | grep -oP '\d+' | head -1)
sudo apt-get install -y nvidia-fabricmanager-${DRIVER_VER}

# Enable Fabric Manager on boot
sudo systemctl enable nvidia-fabricmanager

sudo reboot
```

### 9.6 Verify drivers, NVSwitches, and Fabric Manager

After reboot:

```bash
# Verify all 8 GPUs visible
nvidia-smi -L
# Expected: 8 lines, all NVIDIA H100 80GB HBM3

# Verify NVSwitch device nodes
ls /dev/nvidia-nvswitch*
# Expected: /dev/nvidia-nvswitch0 ... /dev/nvidia-nvswitch3

# Verify Fabric Manager is running and connected
sudo systemctl status nvidia-fabricmanager
# Expected: Active: active (running)
# Log lines: "Connected to 1 node."  "Successfully configured all the available NVSwitches..."
```

### 9.7 Build and run the CUDA smoke test

```bash
# Copy gpu_test.cu to the Ubuntu VM (run from bastion)
virtctl scp gpu_test.cu ubuntu@vm/ubuntu2404-gpu-vm/gpu-vms:/home/ubuntu/ \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

# Compile and run inside the VM
virtctl ssh ubuntu@vm/ubuntu2404-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' \
  -c 'export PATH=/usr/local/cuda/bin:$PATH; nvcc -O2 -o gpu_test gpu_test.cu && ./gpu_test'
```

Expected: `Found 8 GPU(s)` followed by `Result: PASS`. See Part 7.6 for a full explanation of the output.

---

## Quick Reference

```bash
# Set kubeconfig
export KUBECONFIG=/home/nvidia/sno/kubeconfig

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

# virtctl commands — RHEL 9 VM
virtctl start rhel9-gpu-vm -n gpu-vms
virtctl stop rhel9-gpu-vm -n gpu-vms
virtctl restart rhel9-gpu-vm -n gpu-vms
virtctl console rhel9-gpu-vm -n gpu-vms          # serial console (Ctrl+] to exit)
virtctl ssh cloud-user@vmi/rhel9-gpu-vm -n gpu-vms --identity-file ~/.ssh/id_rsa
virtctl vnc rhel9-gpu-vm -n gpu-vms              # requires X forwarding

# virtctl commands — Ubuntu 24.04 VM (node 2)
virtctl start ubuntu2404-gpu-vm -n gpu-vms
virtctl stop ubuntu2404-gpu-vm -n gpu-vms
virtctl restart ubuntu2404-gpu-vm -n gpu-vms
virtctl ssh ubuntu@vm/ubuntu2404-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

# GPU node status
oc describe node lp-nvaie-rh-gpu03 | grep -E "nvidia|gpu" | head -10

# Check GPU + NVSwitch capacity on node
oc get node -o jsonpath='{.items[0].status.capacity}' | python3 -m json.tool | grep nvidia

# Check HCO permittedHostDevices (use v1beta1 to see the real stored value)
kubectl get hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv -o jsonpath='{.spec.permittedHostDevices}' | python3 -m json.tool

# Add NVSwitch to HCO (v1beta1 required)
kubectl patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv --type=json \
  -p='[{"op":"add","path":"/spec/permittedHostDevices/pciHostDevices/-",
        "value":{"pciDeviceSelector":"10de:22a3","resourceName":"nvidia.com/nvswitch"}}]'

# SSH into VM (skip host-key check after restart)
virtctl ssh cloud-user@vm/rhel9-gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' -c '<command>'

# MCO pause/unpause (freeze cluster during VM workloads)
oc patch machineconfigpool master --type=merge -p '{"spec":{"paused":true}}'
oc patch machineconfigpool master --type=merge -p '{"spec":{"paused":false}}'
```
