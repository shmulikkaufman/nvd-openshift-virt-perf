# Phase II Multi-Node Certification — Gap Analysis & Setup Guide

**Target:** NVIDIA-Certified Hypervisor Program, Phase II Multi-Node  
**Stack:** OpenShift + KubeVirt/CNV, 2× DGX H100, ubuntu2404-gpu-vm-gpu02 / ubuntu2404-gpu-vm-gpu03

---

## Current State: Passed vs. Gaps

### PASSED ✅

| Check | Detail |
|---|---|
| IOMMU enabled on both nodes | `intel_iommu=on iommu=pt` in kernel cmdline |
| 8× H100 80GB visible in both VMs | All 8 GPUs confirmed via `nvidia-smi -L` |
| NVIDIA driver 580.159.03 | `nvidia-dkms-580-server-open` in both VMs |
| Fabric Manager active | `nvidia-fabricmanager-580` 580.159.03, `active` in both VMs |
| CUDA Toolkit 13.0 installed | `nvcc` at `/usr/local/cuda/bin/nvcc`, release 13.0 |
| DOCA-OFED installed | OFED-internal-25.10-1.7.1.409 in both VMs |
| SR-IOV Network Operator deployed | `sriov-network-operator` running in `openshift-sriov-network-operator` |
| Both nodes SR-IOV capable | Node label `network-sriov.capable=true` on both |
| 8× CX-7 NICs per node SR-IOV ready | `sriov_totalvfs=16` confirmed on all 8 NICs (PCI: 18:00.0 … dc:00.0) |
| 8 RDMA devices active per node | `mlx5_1 … mlx5_11` ACTIVE on host (enp24s0np0 … enp220s0np0) |
| VMs running and accessible | Both VMs Running, accessible via `virtctl ssh` |

### GAPS ❌

| # | Gap | Impact |
|---|---|---|
| 1 | Cross-node fabric NOT confirmed | Unknown if CX-7 NICs on gpu02/gpu03 share a switch |
| 2 | SR-IOV VFs not created (`numvfs=0`) | No VFs to pass into VMs |
| 3 | No `SriovNetworkNodePolicy` | SR-IOV operator not managing any NIC |
| 4 | No `NetworkAttachmentDefinition` for SR-IOV | No way to attach VFs to VMs |
| 5 | VMs have no secondary (SR-IOV) interfaces | Only masquerade enp1s0 present |
| 6 | No RDMA devices inside VMs | `ls /dev/infiniband/` → NONE |
| 7 | `nvidia-peermem` not loaded | GPUDirect RDMA blocked |
| 8 | `nvcc` not in `$PATH` | CUDA apps can't find compiler |
| 9 | NCCL tests not installed | Can't run NCCL benchmark |
| 10 | No LLM NIM deployment | LLM inference benchmark not ready |

---

## Step-by-Step Setup Guide

### Step 1 — Confirm Cross-Node Fabric Connectivity

Verify that the CX-7 data NICs on gpu02 and gpu03 are on the same switch fabric. This is the prerequisite for everything below.

**On gpu02 (via `oc debug`):**
```bash
oc debug node/lp-nvaie-rh-gpu02 -- nsenter -a -t 1 -- \
  bash -c 'ip addr add 192.168.100.2/24 dev enp24s0np0; sleep 30; ip addr del 192.168.100.2/24 dev enp24s0np0' &
```

**On gpu03 (via `oc debug`, in a separate terminal):**
```bash
oc debug node/lp-nvaie-rh-gpu03 -- nsenter -a -t 1 -- \
  bash -c 'ip addr add 192.168.100.3/24 dev enp24s0np0; ping -c 5 192.168.100.2; ip addr del 192.168.100.3/24 dev enp24s0np0'
```

**Expected:** 0% packet loss. If unreachable, confirm switch VLAN configuration with infra team.

---

### Step 2 — Create SriovNetworkNodePolicy (4 NICs per node)

The PPTX spec requires 4× CX-7 per node. Use the first 4 active data NICs: `enp24s0np0`, `enp64s0np0`, `enp79s0np0`, `enp94s0np0` (mlx5_1, mlx5_4, mlx5_5, mlx5_6).

```yaml
# sriov-policy-cx7-data.yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: cx7-gpu-data
  namespace: openshift-sriov-network-operator
spec:
  resourceName: cx7_gpu_rdma
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  numVfs: 4
  nicSelector:
    pfNames:
      - enp24s0np0
      - enp64s0np0
      - enp79s0np0
      - enp94s0np0
  deviceType: netdevice
  isRdma: true
```

```bash
oc apply -f sriov-policy-cx7-data.yaml
# Wait for nodes to drain/reconfigure (may reboot)
oc get sriovnetworknodestates -n openshift-sriov-network-operator -w
```

> **Note:** Also apply a matching policy for the master node (gpu03 / lp-nvaie-rh-gpu03) using its `nodeSelector`. Or use a label that covers both nodes.

---

### Step 3 — Create NetworkAttachmentDefinition

```yaml
# nad-sriov-cx7-rdma.yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: sriov-cx7-rdma
  namespace: gpu-vms
  annotations:
    k8s.v1.cni.cncf.io/resourceName: openshift.io/cx7_gpu_rdma
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "sriov-cx7-rdma",
      "type": "sriov",
      "ipam": {
        "type": "static"
      }
    }
```

```bash
oc apply -f nad-sriov-cx7-rdma.yaml
```

---

### Step 4 — Update VM Specs to Add SR-IOV Interfaces

Add 4 secondary interfaces to each VM (one per CX-7 data NIC). Edit the VM:

```bash
oc edit vm ubuntu2404-gpu-vm-gpu02 -n gpu-vms
oc edit vm ubuntu2404-gpu-vm-gpu03 -n gpu-vms
```

Add to `spec.template.spec.domain.devices.interfaces`:
```yaml
- name: sriov0
  sriov: {}
- name: sriov1
  sriov: {}
- name: sriov2
  sriov: {}
- name: sriov3
  sriov: {}
```

Add to `spec.template.spec.networks`:
```yaml
- name: sriov0
  multus:
    networkName: sriov-cx7-rdma
- name: sriov1
  multus:
    networkName: sriov-cx7-rdma
- name: sriov2
  multus:
    networkName: sriov-cx7-rdma
- name: sriov3
  multus:
    networkName: sriov-cx7-rdma
```

Restart each VM to pick up the new interfaces:
```bash
virtctl restart ubuntu2404-gpu-vm-gpu02 -n gpu-vms
virtctl restart ubuntu2404-gpu-vm-gpu03 -n gpu-vms
```

**Verify inside VM:**
```bash
ip -br link          # should show enp1s0 + enp2s0 enp3s0 enp4s0 enp5s0
ls /dev/infiniband/  # should show uverbs0 uverbs1 uverbs2 uverbs3
rdma link            # should show mlx5_0 … mlx5_3 ACTIVE
```

**Assign static IPs on RDMA interfaces** (use a non-routed subnet dedicated to RDMA traffic):
```bash
# On gpu02 VM — repeat for each SR-IOV interface
sudo ip addr add 192.168.200.2/24 dev enp2s0
sudo ip addr add 192.168.201.2/24 dev enp3s0
sudo ip addr add 192.168.202.2/24 dev enp4s0
sudo ip addr add 192.168.203.2/24 dev enp5s0

# On gpu03 VM
sudo ip addr add 192.168.200.3/24 dev enp2s0
sudo ip addr add 192.168.201.3/24 dev enp3s0
sudo ip addr add 192.168.202.3/24 dev enp4s0
sudo ip addr add 192.168.203.3/24 dev enp5s0
```

Make persistent via netplan or `/etc/network/interfaces`.

---

### Step 5 — Load nvidia-peermem (GPUDirect RDMA)

Run inside **both VMs**:

```bash
# Load the module
sudo modprobe nvidia-peermem

# Verify
lsmod | grep nvidia_peermem

# Make persistent
echo nvidia-peermem | sudo tee /etc/modules-load.d/nvidia-peermem.conf
```

---

### Step 6 — Fix nvcc PATH

Run inside **both VMs**:

```bash
echo 'export PATH=/usr/local/cuda/bin:$PATH' | sudo tee /etc/profile.d/cuda.sh
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' | sudo tee -a /etc/profile.d/cuda.sh
source /etc/profile.d/cuda.sh

# Verify
nvcc --version
```

---

### Step 7 — Install NCCL and Build nccl-tests

Run inside **both VMs**:

```bash
# Install NCCL (from CUDA repo — already configured)
sudo apt-get install -y libnccl2 libnccl-dev

# Clone and build nccl-tests
git clone https://github.com/NVIDIA/nccl-tests.git /usr/local/nccl-tests
cd /usr/local/nccl-tests
make MPI=0 CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr

# Verify
ls /usr/local/nccl-tests/build/
```

---

### Step 8 — Run Phase II Benchmarks

#### 8a. NCCL All-Reduce (single-node, sanity check)
Run inside each VM independently:
```bash
/usr/local/nccl-tests/build/all_reduce_perf -b 8 -e 8G -f 2 -g 8
```
Expected: near-theoretical NVLink bandwidth (~900 GB/s bus BW).

#### 8b. NCCL All-Reduce (multi-node, cross-VM via RDMA)
Requires MPI. Install on both VMs:
```bash
sudo apt-get install -y openmpi-bin libopenmpi-dev
# Rebuild nccl-tests with MPI
cd /usr/local/nccl-tests && make MPI=1 CUDA_HOME=/usr/local/cuda NCCL_HOME=/usr MPI_HOME=/usr
```

Run from gpu02 VM (targeting both VMs via SSH):
```bash
export NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3   # SR-IOV VF RDMA devices
export NCCL_DEBUG=INFO

mpirun --host 192.168.200.2,192.168.200.3 \
  -np 16 \
  /usr/local/nccl-tests/build/all_reduce_perf -b 8 -e 8G -f 2 -g 8
```

#### 8c. GPUDirect RDMA Bandwidth (Phase II specific test)
```bash
# Install perftest (ib_write_bw etc.)
sudo apt-get install -y perftest

# On gpu03 VM (receiver):
ib_write_bw -d mlx5_0 --use_cuda=0

# On gpu02 VM (sender):
ib_write_bw -d mlx5_0 --use_cuda=0 192.168.200.3
```
Expected: close to line rate (~380 GB/s per port at 400GbE).

---

### Step 9 — LLM NIM (DeepSeek-R1 671B per PPTX spec)

The PPTX Phase II benchmark uses DeepSeek-R1 671B served via NVIDIA NIM.

```bash
# Pull and run NIM container inside VM (requires NGC API key)
docker run --rm --gpus all \
  -e NGC_API_KEY=<your-key> \
  -v /path/to/nim-cache:/opt/nim/.cache \
  -p 8000:8000 \
  nvcr.io/nim/deepseek-ai/deepseek-r1:latest
```

Run inference benchmark using NVIDIA's provided benchmark scripts from the LaunchPad README.

---

## Summary Checklist

```
[x] IOMMU enabled (both nodes)
[x] 8x H100 GPU passthrough (both VMs)
[x] NVIDIA driver 580.159.03 (both VMs)
[x] Fabric Manager active (both VMs)
[x] CUDA Toolkit 13.0 (both VMs)
[x] DOCA-OFED (both VMs)
[x] SR-IOV Network Operator deployed
[x] CX-7 NICs SR-IOV capable (sriov_totalvfs=16)

[ ] Step 1: Confirm cross-node fabric connectivity
[ ] Step 2: SriovNetworkNodePolicy applied, VFs created
[ ] Step 3: NetworkAttachmentDefinition created
[ ] Step 4: VM specs updated, SR-IOV interfaces in VMs, RDMA devices visible
[ ] Step 5: nvidia-peermem loaded in both VMs
[ ] Step 6: nvcc in PATH in both VMs
[ ] Step 7: NCCL + nccl-tests installed and built
[ ] Step 8a: Single-node NCCL test passing
[ ] Step 8b: Multi-node NCCL test passing (cross-VM RDMA)
[ ] Step 8c: GPUDirect RDMA bandwidth test passing
[ ] Step 9: LLM NIM benchmark (DeepSeek-R1 671B)
```
