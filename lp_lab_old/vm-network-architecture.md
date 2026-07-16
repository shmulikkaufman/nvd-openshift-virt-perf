# VM-to-VM GPU Network Architecture

## Current Setup (Masquerade) — Not Suitable for GPU Workloads

```
┌─────────────── gpu02 ────────────────┐     ┌─────────────── gpu03 ────────────────┐
│                                      │     │                                      │
│  VM                                  │     │  VM                                  │
│  ┌──────────────────────────────┐    │     │  ┌──────────────────────────────┐    │
│  │  GPU (VFIO)   enp1s0        │    │     │  │  GPU (VFIO)   enp1s0        │    │
│  │               10.0.2.2      │    │     │  │               10.0.2.2      │    │
│  └──────────┬───────────────────┘    │     │  └──────────┬───────────────────┘    │
│             │ tap / virtio           │     │             │ tap / virtio           │
│  virt-launcher (NAT/DNAT)           │     │  virt-launcher (NAT/DNAT)           │
│             │                        │     │             │                        │
│  OVN-K pod network                  │     │  OVN-K pod network                  │
│             │ Geneve encap           │     │             │ Geneve encap           │
└─────────────┼────────────────────────┘     └─────────────┼────────────────────────┘
              │                                             │
              └──────── management NIC (ens12f0) ──────────┘
                          ~10 Gbps, high latency
                        NAT + overlay + CPU copies
```

**Problems:**
- Every packet goes through NAT and Geneve encapsulation
- CPU involved in every memory copy
- No RDMA capability
- Bandwidth limited to ~10s of Gbps single-stream
- ~4 ms latency (measured)

---

## Optimal Setup: SR-IOV + GPUDirect RDMA

```
┌──────────────────────── gpu02 ─────────────────────────┐     ┌──────────────────────── gpu03 ─────────────────────────┐
│                                                         │     │                                                         │
│  VM (ubuntu2404-gpu-vm-gpu02)                           │     │  VM (ubuntu2404-gpu-vm-gpu03)                           │
│  ┌──────────────────────────────────────────────────┐   │     │  ┌──────────────────────────────────────────────────┐   │
│  │                                                  │   │     │  │                                                  │   │
│  │  H100 #0 <──GPUDirect──> VF0 (enp2s0)          │   │     │  │  H100 #0 <──GPUDirect──> VF0 (enp2s0)          │   │
│  │  H100 #1 <──GPUDirect──> VF1 (enp3s0)          │   │     │  │  H100 #1 <──GPUDirect──> VF1 (enp3s0)          │   │
│  │  H100 #2 <──GPUDirect──> VF2 (enp4s0)          │   │     │  │  H100 #2 <──GPUDirect──> VF2 (enp4s0)          │   │
│  │  ...                                            │   │     │  │  ...                                            │   │
│  │  H100 #7 <──GPUDirect──> VF7 (enp9s0)          │   │     │  │  H100 #7 <──GPUDirect──> VF7 (enp9s0)          │   │
│  │                                                  │   │     │  │                                                  │   │
│  │  enp1s0 (masquerade) — management only          │   │     │  │  enp1s0 (masquerade) — management only          │   │
│  └──────────────────┬───────────────────────────────┘   │     │  └──────────────────┬───────────────────────────────┘   │
│                     │ PCI passthrough (no hypervisor)   │     │                     │ PCI passthrough (no hypervisor)   │
│  ┌──────────────────▼───────────────────────────────┐   │     │  ┌──────────────────▼───────────────────────────────┐   │
│  │  CX7 PF0   CX7 PF1   ...   CX7 PF7              │   │     │  │  CX7 PF0   CX7 PF1   ...   CX7 PF7              │   │
│  │  enp24s0   enp64s0         enp220s0              │   │     │  │  enp24s0   enp64s0         enp220s0              │   │
│  │            8 x 400 GbE ConnectX-7                │   │     │  │            8 x 400 GbE ConnectX-7                │   │
│  └──────────────────┬───────────────────────────────┘   │     │  └──────────────────┬───────────────────────────────┘   │
└─────────────────────┼───────────────────────────────────┘     └─────────────────────┼───────────────────────────────────┘
                      │                                                                │
                      └───────────────┐        ┌───────────────────────────────────────┘
                                      │        │
                               ┌──────▼────────▼──────┐
                               │    400 GbE / IB       │
                               │    switch fabric      │
                               │  (shared between      │
                               │   gpu02 & gpu03)      │
                               └───────────────────────┘

NCCL data path (zero CPU involvement):
  GPU mem ──DMA──> CX7 NIC ──wire──> switch ──wire──> CX7 NIC ──DMA──> GPU mem
```

---

## Performance Comparison

| | Current (Masquerade) | Optimal (SR-IOV + GPUDirect RDMA) |
|---|---|---|
| Transport | Masquerade NAT + Geneve overlay | SR-IOV VF — bare metal PCI passthrough |
| Protocol | TCP over OVN-Kubernetes | RDMA / RoCE |
| CPU involvement | Every packet copied by CPU | Zero-copy (GPUDirect RDMA) |
| Bandwidth | ~10s Gbps, single-stream | Up to 8 × 400 Gbps = 3.2 Tbps aggregate |
| Latency | ~4 ms (measured) | ~1–2 µs |
| NCCL transport | UCX/TCP | UCX/RDMA |

---

## Hardware (per node)

- **GPUs:** 8× NVIDIA H100 SXM5 80GB (passed to VM via VFIO)
- **NICs:** 8× NVIDIA ConnectX-7 400GbE (one dedicated per GPU for GPUDirect RDMA affinity)
- **DPU:** 1× NVIDIA BlueField-3 (management / cluster network)
- **Cluster:** Single Node OpenShift (SNO) + gpu02/gpu03 worker nodes, KubeVirt/CNV

---

## What Needs to Be Built

1. **SR-IOV Network Operator** — deployed in the OpenShift cluster to manage VF lifecycle
2. **SriovNetworkNodePolicy** — configures each node to carve VFs from the 8 ConnectX-7 data NICs
3. **NetworkAttachmentDefinition** — Multus configuration exposing the VF pool to VMs
4. **VM spec update** — add 8 secondary interfaces to each VM, each requesting one VF (one per GPU NIC)
5. **Inside VM** — load `nvidia-peermem` kernel module to enable GPUDirect RDMA between GPU and VF; NCCL picks up RDMA devices automatically

### Prerequisite

Confirm the 8× ConnectX-7 NICs on gpu02 and gpu03 are connected to the **same switch fabric**. Both nodes show `Link detected: yes` at 400 GbE on all 8 ports, which strongly suggests they are.
