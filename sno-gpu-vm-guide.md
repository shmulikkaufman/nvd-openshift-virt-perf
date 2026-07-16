# SNO + OpenShift Virtualization + NVIDIA GPU Operator + GPU VM Passthrough

A step-by-step guide for deploying NVIDIA GPU-backed virtual machines on Single Node
OpenShift (SNO). Covers two passthrough approaches: pure VFIO (KubeVirt device plugin)
and GPU Operator managed (sandboxed workload mode).

Replace all `<placeholder>` values with your environment's specifics before applying any
manifest or command.

---

## Table of Contents

- [Environment placeholders](#environment-placeholders)
- [Part 1 — SNO Installation: Agent-Based Installer](#part-1--sno-installation)
  - [1.1 Prerequisites](#11-prerequisites)
  - [1.2 Network planning (dual-NIC nodes)](#12-network-planning-dual-nic-nodes)
  - [1.3 Install configuration files](#13-install-configuration-files)
  - [1.4 Build the agent ISO and boot](#14-build-the-agent-iso-and-boot)
  - [1.5 Post-install access](#15-post-install-access)
  - [1.6 Dual-NIC kubelet IP fix](#16-dual-nic-kubelet-ip-fix-apply-if-applicable)
- [Part 1B — SNO Installation: Assisted Installer](#part-1b--sno-installation-assisted-installer)
  - [When to choose Assisted vs Agent-Based](#when-to-choose-assisted-installer-vs-agent-based)
  - [1B.1 Prerequisites and DNS records](#1b1-prerequisites)
  - [1B.2 Option 1 — Web UI (console.redhat.com)](#1b2-option-1--web-ui-consoleredhatcom)
  - [1B.3 Static network configuration (dual-NIC nodes)](#1b3-static-network-configuration-dual-nic-nodes)
  - [1B.4 Set the hostname](#1b4-set-the-hostname-via-discovery-iso)
  - [1B.5 Option 2 — API with aicli](#1b5-option-2--api-with-aicli)
  - [1B.6 Option 3 — Self-hosted Assisted Service](#1b6-option-3--self-hosted-assisted-service)
  - [1B.7 Kubeconfig and post-install access](#1b7-kubeconfig-and-post-install-access)
- [Part 2 — IOMMU and VFIO Host Setup](#part-2--iommu-and-vfio-host-setup)
  - [2.1 Enable IOMMU](#21-enable-iommu)
  - [2.2 Bind GPUs to vfio-pci (pure VFIO only)](#22-bind-gpus-to-vfio-pci-pure-vfio-approach-only)
- [Part 2B — CPU Manager and Dedicated CPU Placement](#part-2b--cpu-manager-and-dedicated-cpu-placement-for-vms)
  - [2B.1 KubeletConfig for master MCP](#2b1-create-a-kubeletconfig-for-the-master-machineconfigpool)
  - [2B.2 KubeletConfig for worker MCP](#2b2-create-a-kubeletconfig-for-the-worker-machineconfigpool-if-workers-exist)
  - [2B.3 Enable dedicated CPU placement in the VM spec](#2b3-enable-dedicated-cpu-placement-in-the-vm-spec)
  - [2B.4 Complete VM spec excerpt](#2b4-complete-vm-spec-excerpt-with-dedicated-cpus)
  - [2B.5 Verify CPU pinning](#2b5-verify-cpu-pinning-is-active-on-a-running-vm)
  - [2B.6 Troubleshooting](#2b6-troubleshooting)
- [Part 3 — Storage (LVMS)](#part-3--storage-lvms)
  - [3.1 Install the LVMS Operator](#31-install-the-lvms-operator)
  - [3.2 Create the LVMCluster](#32-create-the-lvmcluster)
  - [3.3 Create an Immediate-binding StorageClass](#33-create-an-immediate-binding-storageclass)
- [Part 4 — OpenShift Virtualization (KubeVirt / CNV)](#part-4--openshift-virtualization-kubevirt--cnv)
  - [4.1 Install the Operator](#41-install-the-operator)
  - [4.2 Create the HyperConverged CR](#42-create-the-hyperconverged-cr)
  - [4.3 Install virtctl](#43-install-virtctl)
- [Part 5 — GPU VM Passthrough: Approach A (Pure VFIO)](#part-5--gpu-vm-passthrough-approach-a-pure-vfio)
  - [5.1 Find GPU PCI IDs](#51-find-gpu-pci-ids)
  - [5.2 Expose devices through HyperConverged](#52-expose-devices-through-hyperconverged-permittedhostdevices)
  - [5.3 Create the VM](#53-create-the-vm)
  - [5.4 Access the VM](#54-access-the-vm)
  - [5.5 Install NVIDIA driver inside the VM](#55-install-nvidia-driver-inside-the-vm-ubuntu-2404-example)
  - [5.6 Verify](#56-verify)
- [Part 6 — GPU VM Passthrough: Approach B (GPU Operator Managed)](#part-6--gpu-vm-passthrough-approach-b-gpu-operator-managed)
  - [6.1 Install the NVIDIA GPU Operator](#61-install-the-nvidia-gpu-operator)
  - [6.2 Create a ClusterPolicy with sandbox workload mode](#62-create-a-clusterpolicy-with-sandbox-workload-mode-enabled)
  - [6.3 Label the node for sandbox workloads](#63-label-the-node-for-sandbox-workloads-if-not-auto-labeled)
  - [6.4 Verify GPU Operator vfio-pci binding](#64-verify-gpu-operator-vfio-pci-binding)
  - [6.5 Expose devices through HyperConverged](#65-expose-devices-through-hyperconverged)
  - [6.6 Create the VM](#66-create-the-vm)
  - [6.7 Install the NVIDIA driver inside the VM](#67-install-the-nvidia-driver-inside-the-vm)
  - [6.8 Approach comparison](#68-approach-comparison)
- [Part 7 — SSH Access to VMs](#part-7--ssh-access-to-vms)
  - [7.1 virtctl ssh](#71-virtctl-ssh-direct-requires-proper-cnv-networking)
  - [7.2 NodePort SSH (reliable fallback)](#72-nodeport-ssh-reliable-fallback)
- [Part 8 — Adding Worker Nodes](#part-8--adding-worker-nodes)
  - [8.1 Generate a worker agent ISO](#81-generate-a-worker-agent-iso)
  - [8.2 Apply worker MachineConfigs for IOMMU and VFIO](#82-apply-worker-machineconfigs-for-iommu-and-vfio)
  - [8.3 Add per-worker LVMS storage](#83-add-per-worker-lvms-storage)
- [Troubleshooting](#troubleshooting)
- [Quick Reference](#quick-reference)

---

## Environment placeholders

| Placeholder | Description |
|-------------|-------------|
| `<cluster-name>` | OCP cluster name (e.g. `sno`) |
| `<base-domain>` | DNS base domain (e.g. `example.com`) |
| `<node-hostname>` | Bare metal node hostname (e.g. `gpu-node-01`) |
| `<management-ip>` | Management NIC static IP |
| `<management-nic>` | Management NIC interface name (e.g. `ens3f0np0`) |
| `<ovn-nic>` | NIC enslaved into `br-ex` by OVN (e.g. `ens6f0np0`) |
| `<management-mac>` | MAC address of the management NIC |
| `<gateway>` | Default gateway |
| `<dns-server>` | DNS resolver IP |
| `<os-disk>` | Disk for the OS (e.g. `/dev/nvme0n1`) |
| `<storage-disk>` | Free disk for VM storage (e.g. `/dev/nvme1n1`) |
| `<gpu-pci-id>` | GPU PCI device ID (e.g. `10de:2330`) |
| `<nvswitch-pci-id>` | NVSwitch PCI device ID if present (e.g. `10de:22a3`) |
| `<ocp-version>` | Target OCP version (e.g. `4.17.0`) |
| `<ssh-public-key>` | Your SSH public key |

---

## Part 1 — SNO Installation

### 1.1 Prerequisites

- OpenShift pull secret from [console.redhat.com](https://console.redhat.com)
- `openshift-install` binary matching the target OCP version
- SSH key pair

```bash
OCP_VERSION=<ocp-version>
curl -Lo /tmp/ocp.tar.gz \
  https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-install-linux.tar.gz
tar -xzf /tmp/ocp.tar.gz -C /usr/local/bin openshift-install
openshift-install version
```

### 1.2 Network planning (dual-NIC nodes)

On nodes with two or more NICs, OVN-Kubernetes enslaves one NIC into `br-ex` at
install time, changing its IP. The kubelet must bind to the **management NIC IP**.

Decide the NIC roles before installation:

| NIC | Role |
|-----|------|
| `<management-nic>` | Kubelet, API server, etcd, SSH — set a static IP |
| `<ovn-nic>` | OVN external bridge — leave unconfigured in agent-config |

The `rendezvousIP` in `agent-config.yaml` must be the management NIC's static IP.

### 1.3 Install configuration files

```bash
mkdir -p ~/sno/install-dir
```

**`~/sno/install-dir/install-config.yaml`:**

```yaml
apiVersion: v1
baseDomain: <base-domain>
metadata:
  name: <cluster-name>
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: 1
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
  installationDisk: <os-disk>
pullSecret: '<your-pull-secret>'
sshKey: '<ssh-public-key>'
```

**`~/sno/install-dir/agent-config.yaml`:**

```yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: <cluster-name>
rendezvousIP: <management-ip>
hosts:
- hostname: <node-hostname>
  role: master
  interfaces:
  - name: <management-nic>
    macAddress: "<management-mac>"
  networkConfig:
    interfaces:
    - name: <management-nic>
      type: ethernet
      state: up
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: <management-ip>
          prefix-length: 24
    dns-resolver:
      config:
        server:
        - <dns-server>
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: <gateway>
        next-hop-interface: <management-nic>
        table-id: 254
```

> **Only configure the management NIC.** Leave `<ovn-nic>` out of agent-config —
> OVN-Kubernetes takes ownership of it automatically.

### 1.4 Build the agent ISO and boot

```bash
cd ~/sno
openshift-install agent create image --dir install-dir/
# ISO is at: install-dir/agent.x86_64.iso
# Boot the node from it via USB or BMC virtual media
```

Monitor progress:

```bash
openshift-install agent wait-for bootstrap-complete --dir install-dir/ --log-level=info
openshift-install agent wait-for install-complete   --dir install-dir/ --log-level=info
```

Total time: ~45–60 minutes.

### 1.5 Post-install access

```bash
cp ~/sno/install-dir/auth/kubeconfig ~/.kube/config
export KUBECONFIG=~/.kube/config
oc get nodes
# Expected: <node-hostname>  Ready  master  ...
```

### 1.6 Dual-NIC kubelet IP fix (apply if applicable)

OVN's `configure-ovs.sh` may set `KUBELET_NODE_IP` to the OVN bridge IP after every
reboot instead of the management NIC IP. This breaks etcd, router pods, and API certs.

Fix: a higher-priority systemd drop-in that survives MCO reboots.

Compute the base64-encoded drop-in:

```bash
printf '[Service]\nEnvironment="KUBELET_NODE_IP=<management-ip>" "KUBELET_NODE_IPS=<management-ip>"\n' \
  | base64 -w0
# Copy the output — you'll use it in the MachineConfig below
```

Apply via MachineConfig:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 99-master-kubelet-node-ip
spec:
  config:
    ignition:
      version: 3.5.0
    storage:
      files:
      - path: /etc/systemd/system/kubelet.service.d/21-node-ip-override.conf
        mode: 0644
        contents:
          source: "data:text/plain;charset=utf-8;base64,<base64-output-from-above>"
```

---

## Part 1B — SNO Installation: Assisted Installer

The Assisted Installer is a guided, web-based (or API-driven) alternative to the
agent-based installer. It handles prerequisite validation, network configuration,
and progress monitoring through a UI at console.redhat.com or a self-hosted instance.
No `install-config.yaml` or `agent-config.yaml` files are needed.

### When to choose Assisted Installer vs Agent-Based

| Aspect | Assisted Installer | Agent-Based |
|--------|--------------------|-------------|
| Configuration method | Web UI or REST API | YAML files |
| Prerequisites validation | Built-in (DNS, NTP, hardware) | Manual |
| Disconnected/air-gapped | Self-hosted only | Yes (mirror registry) |
| Static network config | NMState YAML per host in UI | NMState in `agent-config.yaml` |
| Automation / GitOps | API / `aicli` CLI | `openshift-install` CLI |

### 1B.1 Prerequisites

**DNS records — must exist before starting installation:**

| Record | Type | Value |
|--------|------|-------|
| `api.<cluster-name>.<base-domain>` | A | `<management-ip>` |
| `api-int.<cluster-name>.<base-domain>` | A | `<management-ip>` |
| `*.apps.<cluster-name>.<base-domain>` | A | `<management-ip>` |

Verify DNS resolution before proceeding:

```bash
dig api.<cluster-name>.<base-domain> +short
dig api-int.<cluster-name>.<base-domain> +short
dig test.apps.<cluster-name>.<base-domain> +short
# All three must resolve to <management-ip>
```

**Minimum hardware for SNO:**

| Resource | Minimum |
|----------|---------|
| CPU | 8 physical cores |
| RAM | 32 GB |
| Disk (OS) | 120 GB |
| NTP | Required (reachable NTP server) |

### 1B.2 Option 1 — Web UI (console.redhat.com)

1. Go to [console.redhat.com/openshift/create](https://console.redhat.com/openshift/create)
2. Select the **Datacenter** tab → **Assisted Installer**
3. Fill in the cluster details:
   - **Cluster name:** `<cluster-name>`
   - **Base domain:** `<base-domain>`
   - **OpenShift version:** select your target version
   - **CPU architecture:** x86_64
4. Under **Cluster configuration**, enable **Install single node OpenShift (SNO)**
5. Paste your pull secret from console.redhat.com/openshift/install/pull-secret
6. Click **Next** to reach the **Host discovery** step

#### Generate the discovery ISO

In the **Host discovery** step:

1. Click **Add hosts** → **Generate Discovery ISO**
2. Choose **Full image** (recommended) or **Minimal image**
   - Full: ~1 GB, works without internet access during boot
   - Minimal: ~100 MB, downloads components at boot (requires internet)
3. (Optional) Add your SSH public key for post-installation host access
4. For **static networking**, see Section 1B.3 before generating
5. Click **Generate Discovery ISO** and download `discovery_image_<cluster-name>.iso`

Boot the node from this ISO (USB drive or BMC virtual media).

#### Monitor host discovery

Within ~5 minutes the node appears in the UI under **Host inventory** with status
`Discovering`. Wait for it to reach **Ready** (hardware validated).

If the node shows **Insufficient** or **Not ready**, click it to see which checks
failed. Common failures:

| Failure | Fix |
|---------|-----|
| DNS not configured | Add the three DNS records from Section 1B.1 |
| Hostname not set | See Section 1B.4 |
| NTP unreachable | Ensure the node can reach an NTP server |
| Disk too small | Use a disk ≥ 120 GB |
| Wrong NIC selected | See Section 1B.3 |

#### Configure networking and install

1. In the **Networking** step, select the management NIC as the **primary NIC**
2. Verify the API VIP and Ingress VIP resolve to `<management-ip>`
3. Click **Next** → review the summary → **Install cluster**

Monitor the progress bar. Total time: ~45–60 minutes.

After installation, download the kubeconfig:

```bash
# Download from the UI (Cluster → Actions → Download kubeconfig)
# or via aicli (see Section 1B.5)
cp ~/Downloads/kubeconfig ~/.kube/config
export KUBECONFIG=~/.kube/config
oc get nodes
```

### 1B.3 Static network configuration (dual-NIC nodes)

For nodes with multiple NICs or no DHCP, provide NMState configuration in the
discovery ISO so the node boots with the correct IP and routes.

In the **Host discovery** step, before clicking **Generate Discovery ISO**:

1. Click **Configure via NMState** (or **Network configuration** depending on UI version)
2. Provide an NMState mapping: MAC address of the management NIC → NMState YAML

Example NMState YAML (replace values):

```yaml
interfaces:
- name: <management-nic>
  type: ethernet
  state: up
  ipv4:
    enabled: true
    dhcp: false
    address:
    - ip: <management-ip>
      prefix-length: 24
dns-resolver:
  config:
    server:
    - <dns-server>
routes:
  config:
  - destination: 0.0.0.0/0
    next-hop-address: <gateway>
    next-hop-interface: <management-nic>
    table-id: 254
```

In the **MAC address to interface mapping** field, provide:

```yaml
- mac_address: "<management-mac>"
  interfaces:
  - name: <management-nic>
    mac_address: "<management-mac>"
```

> **Leave the OVN NIC unconfigured.** OVN-Kubernetes takes ownership of it during
> installation. Configuring it in NMState may conflict with `configure-ovs.sh`.

### 1B.4 Set the hostname via discovery ISO

If the node boots with an auto-generated hostname (e.g. `localhost`), set it
in the Host inventory UI before installation:

1. Click the discovered host row
2. Click the pencil icon next to the hostname
3. Enter `<node-hostname>`
4. Save — the host re-validates

Alternatively, set it in the NMState config by adding to the interface YAML:

```yaml
# This does not set the hostname directly; use the UI or set it in cloud-init post-install
```

Post-install hostname fix if needed:

```bash
ssh core@<management-ip>
sudo hostnamectl set-hostname <node-hostname>
sudo reboot
```

### 1B.5 Option 2 — API with aicli

`aicli` is the official CLI for the Assisted Service API. It supports both the
hosted service at console.redhat.com and self-hosted deployments.

```bash
pip install aicli
```

Configure credentials:

```bash
# For console.redhat.com (uses your Red Hat SSO token via offline token)
export AI_OFFLINETOKEN=$(cat ~/offline-token.txt)   # from console.redhat.com/openshift/token

# For a self-hosted Assisted Service
export AI_URL=http://<assisted-service-ip>:8090
```

Create the SNO cluster and trigger installation:

```bash
# 1. Create the cluster definition
cat > cluster.yml << EOF
name: <cluster-name>
openshift_version: "<ocp-version>"
base_dns_domain: <base-domain>
pull_secret: $(cat ~/pull-secret.txt)
ssh_public_key: $(cat ~/.ssh/id_rsa.pub)
high_availability_mode: None          # None = SNO
user_managed_networking: false
EOF

aicli create cluster <cluster-name> --paramfile cluster.yml

# 2. Create and download the discovery ISO
aicli create iso <cluster-name>
aicli download iso <cluster-name> -p /tmp/

# 3. Boot the node, then list discovered hosts
aicli list hosts

# 4. (Optional) Set static network config for a host
aicli update host <host-id> --paramfile nmstate.yml

# 5. Wait for hosts to be Ready, then install
aicli start cluster <cluster-name>

# 6. Monitor installation
aicli info cluster <cluster-name>

# 7. Download kubeconfig after completion
aicli download kubeconfig <cluster-name> -p ~/.kube/
```

NMState network config for a host (pass via `--nmstate-file` or through the REST API
`PATCH /v2/infra-envs/{id}/hosts/{hostId}` with the `network_info_json` body):

> **Verify this schema against your aicli version** — the paramfile field names for host
> network updates (`network_yaml`, `nmstate_config`, etc.) have changed across aicli
> releases. Run `aicli update host --help` to confirm supported options.

```yaml
# NMState YAML to pass as the network_yaml value
interfaces:
- name: <management-nic>
  type: ethernet
  state: up
  ipv4:
    enabled: true
    dhcp: false
    address:
    - ip: <management-ip>
      prefix-length: 24
dns-resolver:
  config:
    server:
    - <dns-server>
routes:
  config:
  - destination: 0.0.0.0/0
    next-hop-address: <gateway>
    next-hop-interface: <management-nic>
```

### 1B.6 Option 3 — Self-hosted Assisted Service

If the cluster has no internet access, run the Assisted Service locally.

The self-hosted Assisted Service is delivered via the **Multicluster Engine (MCE)** operator,
which is also bundled with Red Hat Advanced Cluster Management (RHACM). Install it through OLM:

```yaml
# 1. Create the MCE subscription (adjust channel to your OCP version)
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: multicluster-engine
  namespace: multicluster-engine
spec:
  name: multicluster-engine
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  channel: stable-2.7
  installPlanApproval: Automatic
```

```bash
oc new-project multicluster-engine
oc apply -f mce-subscription.yaml

# Wait for MCE CSV to reach Succeeded
oc get csv -n multicluster-engine -w

# Create a minimal MultiClusterEngine CR to activate the Assisted Service
cat <<EOF | oc apply -f -
apiVersion: multicluster.openshift.io/v1
kind: MultiClusterEngine
metadata:
  name: multiclusterengine
spec:
  availabilityConfig: Basic
EOF
```

Once MCE is running, create an `AgentServiceConfig` to configure the Assisted Service:

```bash
cat <<EOF | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: AgentServiceConfig
metadata:
  name: agent
spec:
  databaseStorage:
    storageClassName: <storageclass>
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 10Gi
  filesystemStorage:
    storageClassName: <storageclass>
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 100Gi
  imageStorage:
    storageClassName: <storageclass>
    accessModes: [ReadWriteOnce]
    resources:
      requests:
        storage: 50Gi
  osImages:
  - openshiftVersion: "<ocp-version-major-minor>"
    version: "<coreos-version>"
    url: "<mirror-coreos-iso-url>"
    cpuArchitecture: x86_64
EOF
```

Point `aicli` at the self-hosted URL:

```bash
export AI_URL=https://$(oc get route assisted-service -n multicluster-engine -o jsonpath='{.spec.host}')
```

Then follow the same `aicli` steps from Section 1B.5.

### 1B.7 Kubeconfig and post-install access

```bash
export KUBECONFIG=~/.kube/config
oc get nodes
# Expected: <node-hostname>  Ready  master

# SSH to the node (CoreOS uses the 'core' user)
ssh core@<management-ip>
```

Apply the dual-NIC kubelet IP fix from Part 1.6 if the node has multiple NICs.

---

## Part 2 — IOMMU and VFIO Host Setup

GPU PCI passthrough requires IOMMU in the kernel and the `vfio-pci` driver bound to
the GPU devices at boot time. Apply these MachineConfigs before installing the
GPU Operator or OpenShift Virtualization.

### 2.1 Enable IOMMU

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
  - intel_iommu=on   # use amd_iommu=on on AMD systems
  - iommu=pt
```

### 2.2 Bind GPUs to vfio-pci (pure VFIO approach only)

Skip this section if you are using the GPU Operator managed approach — the Operator's
`vfioManager` component handles driver binding at runtime.

Compute the base64 values:

```bash
# Replace the PCI IDs with your GPU (and NVSwitch if present)
printf 'softdep nvidia pre: vfio-pci\noptions vfio-pci ids=<gpu-pci-id>,<nvswitch-pci-id>\n' | base64 -w0
# If there is no NVSwitch: ids=<gpu-pci-id>

printf 'vfio-pci\n' | base64 -w0
```

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
          source: "data:text/plain;charset=utf-8;base64,<base64-of-vfio-conf>"
      - path: /etc/modules-load.d/vfio-pci.conf
        mode: 0644
        contents:
          source: "data:text/plain;charset=utf-8;base64,<base64-of-vfio-pci>"
```

Apply both MachineConfigs and wait for the node to reboot:

```bash
oc apply -f 100-master-iommu.yaml
oc apply -f 100-master-vfio-pci-gpu.yaml

oc get machineconfigpool master -w
# Wait for: UPDATED=True  UPDATING=False  DEGRADED=False
```

Verify after reboot:

```bash
oc debug node/<node-hostname> -- chroot /host sh -c "
  for dev in \$(lspci -d <gpu-pci-id>: -D | awk '{print \$1}'); do
    driver=\$(readlink /sys/bus/pci/devices/\$dev/driver 2>/dev/null | xargs basename 2>/dev/null || echo NONE)
    echo \"\$dev -> \$driver\"
  done"
# Expected: all GPU devices -> vfio-pci
```

---

## Part 2B — CPU Manager and Dedicated CPU Placement for VMs

`dedicatedCpuPlacement: true` and `isolateEmulatorThread: true` in the VM spec pin
each vCPU to an exclusive host CPU and give the QEMU emulator thread its own
dedicated CPU. This eliminates CPU sharing between VMs and host workloads, which is
critical for latency-sensitive or high-throughput GPU compute workloads.

These settings require **CPU Manager** with the `static` policy on every node that
will run the VM. CPU Manager is configured via a `KubeletConfig` object. In OpenShift,
MCO processes the KubeletConfig, renders it into a MachineConfig, and **reboots the
node** to apply it — the same as any other MachineConfig change. Plan for a node reboot
when applying this for the first time.

### 2B.1 Create a KubeletConfig for the master MachineConfigPool

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: cpu-manager-master
spec:
  machineConfigPoolSelector:
    matchLabels:
      machineconfiguration.openshift.io/mcp: master
  kubeletConfig:
    cpuManagerPolicy: static
    cpuManagerReconcilePeriod: 5s
    reservedSystemCPUs: "0-1"      # reserve 2 CPUs for OS and kubelet; adjust to your core count
    topologyManagerPolicy: single-numa-node
```

> **`reservedSystemCPUs`** — CPU Manager requires a non-empty reservation. Reserve
> enough for OS daemons, kubelet, and any host-network pods. On a 112-core node,
> reserving `0-3` (4 cores) is typical. On a smaller node, `0-1` is the minimum.
>
> **`topologyManagerPolicy: single-numa-node`** — aligns CPU, memory, and PCI
> device allocation to the same NUMA node. Required for NVLink-attached GPUs
> (H100 SXM) where the GPU is topologically bound to specific CPU cores.

```bash
oc apply -f kubeletconfig-cpu-manager-master.yaml

# MCO renders the KubeletConfig into a MachineConfig and reboots the node — this takes several minutes
oc get machineconfigpool master -w
# Expected: UPDATED=True  UPDATING=False  DEGRADED=False
```

Verify CPU Manager is active:

```bash
oc debug node/<node-hostname> -- chroot /host \
  cat /var/lib/kubelet/cpu_manager_state
# Expected: a JSON object with "defaultCpuSet" and "entries" keys
```

### 2B.2 Create a KubeletConfig for the worker MachineConfigPool (if workers exist)

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: cpu-manager-worker
spec:
  machineConfigPoolSelector:
    matchLabels:
      machineconfiguration.openshift.io/mcp: worker
  kubeletConfig:
    cpuManagerPolicy: static
    cpuManagerReconcilePeriod: 5s
    reservedSystemCPUs: "0-1"
    topologyManagerPolicy: single-numa-node
```

```bash
oc apply -f kubeletconfig-cpu-manager-worker.yaml
oc get machineconfigpool worker -w
```

### 2B.3 Enable dedicated CPU placement in the VM spec

Add two fields to the VM's `domain.cpu` section:

```yaml
domain:
  cpu:
    cores: 16
    sockets: 1
    threads: 1
    dedicatedCpuPlacement: true     # pin each vCPU to an exclusive host CPU
    isolateEmulatorThread: true     # give the QEMU emulator its own dedicated CPU
```

`isolateEmulatorThread: true` allocates one **additional** host CPU beyond the
`cores × sockets × threads` count to run the QEMU emulator thread in isolation.
A VM with `cores: 16` and `isolateEmulatorThread: true` consumes **17** host CPUs.
Ensure the node has enough allocatable CPUs after accounting for `reservedSystemCPUs`.

> **KubeVirt automatically sets the virt-launcher pod's cpu requests/limits** based on
> the VM's `cores × sockets × threads` topology. You do not set cpu resource
> requests/limits in the VM spec — KubeVirt derives them and creates a Guaranteed QoS
> pod automatically. The `domain.resources` block in the VM spec is for memory only.

### 2B.4 Complete VM spec excerpt with dedicated CPUs

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: gpu-vm
  namespace: gpu-vms
spec:
  runStrategy: Always
  template:
    spec:
      domain:
        cpu:
          cores: 16
          sockets: 1
          threads: 1
          dedicatedCpuPlacement: true
          isolateEmulatorThread: true
        machine:
          type: q35
        memory:
          guest: 64Gi
        resources:
          requests:
            memory: 64Gi
          limits:
            memory: 64Gi
        devices:
          # ... disks, interfaces, hostDevices as shown in Parts 5 and 6
```

### 2B.5 Verify CPU pinning is active on a running VM

```bash
# Find the virt-launcher pod for the VM
LAUNCHER=$(oc get pod -n gpu-vms -l kubevirt.io=virt-launcher \
  -o jsonpath='{.items[0].metadata.name}')

# Check the pod's CPU resource limits
oc get pod "$LAUNCHER" -n gpu-vms \
  -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool

# On the node: verify cpuset is assigned (shows dedicated CPU cores)
oc debug node/<node-hostname> -- chroot /host \
  cat /var/lib/kubelet/cpu_manager_state | python3 -m json.tool
# Look for a "entries" block with the virt-launcher container ID and its cpuset
```

### 2B.6 Troubleshooting

**VM stuck in `Scheduling` with `Unschedulable`:**

```bash
oc describe vmi gpu-vm -n gpu-vms | grep -A5 "Conditions\|Message"
```

Common causes:
- `reservedSystemCPUs` too large — leaves fewer allocatable CPUs than the VM requests
- `isolateEmulatorThread: true` requires one extra CPU; node may not have enough
- CPU Manager not yet applied (KubeletConfig still reconciling)

**KubeletConfig not applying:**

```bash
oc get kubeletconfig cpu-manager-master -o yaml | grep -A5 "conditions\|status"
oc get machineconfigpool master -o yaml | grep -A5 "conditions"
```

**Check actual allocatable CPUs on the node:**

```bash
oc describe node <node-hostname> | grep -E "Allocatable|cpu"
# CPU allocatable = total CPUs - reservedSystemCPUs
```

---

## Part 3 — Storage (LVMS)

VMs need persistent block storage. LVMS provisions LVM thin volumes from bare disks
and exposes them via a `topolvm.io` StorageClass.

### 3.1 Install the LVMS Operator

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
  channel: stable-<ocp-version-major-minor>   # e.g. stable-4.17
  installPlanApproval: Automatic
```

```bash
oc apply -f lvms-install.yaml
oc get pods -n openshift-storage -w
```

### 3.2 Create the LVMCluster

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
        - <storage-disk>   # use /dev/disk/by-id/... for stability across reboots
      thinPoolConfig:
        name: thin-pool
        sizePercent: 90
        overprovisionRatio: 10
      fstype: xfs
```

> **Always use `/dev/disk/by-id/` paths** rather than `/dev/nvme*` paths. NVMe
> enumeration order can change after reboots triggered by MCO kernel-arg changes.

```bash
oc apply -f lvmcluster.yaml
oc get lvmcluster -n openshift-storage -w
# Expected: STATUS=Ready
```

### 3.3 Create an Immediate-binding StorageClass

CDI (VM disk import) requires `volumeBindingMode: Immediate` so PVCs can bind
without a running pod. The default LVMS StorageClass uses `WaitForFirstConsumer`.

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

---

## Part 4 — OpenShift Virtualization (KubeVirt / CNV)

### 4.1 Install the Operator

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
oc apply -f cnv-install.yaml
oc get csv -n openshift-cnv -w | grep kubevirt
# Wait for: PHASE=Succeeded
```

### 4.2 Create the HyperConverged CR

```yaml
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
```

```bash
oc apply -f hyperconverged.yaml
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
# Expected: True
```

### 4.3 Install virtctl

```bash
ROUTE=$(oc get route hyperconverged-cluster-cli-download -n openshift-cnv \
  -o jsonpath='{.spec.host}')
curl -Lo /usr/local/bin/virtctl "https://${ROUTE}/amd64/linux/virtctl"
chmod +x /usr/local/bin/virtctl
virtctl version
```

---

## Part 5 — GPU VM Passthrough: Approach A (Pure VFIO)

In this approach the GPU is bound to `vfio-pci` on the host (Part 2.2), KubeVirt's
device plugin exposes it to VMs, and there is no NVIDIA driver on the host. The guest
installs its own NVIDIA driver inside the VM.

### 5.1 Find GPU PCI IDs

```bash
oc debug node/<node-hostname> -- chroot /host sh -c 'lspci -nn | grep -i nvidia'
# Note the [vendor:device] IDs — e.g. [10de:2330] for GPU, [10de:22a3] for NVSwitch
```

### 5.2 Expose devices through HyperConverged (permittedHostDevices)

> **Always patch via `v1beta1`** — the default `v1` API silently prunes
> `permittedHostDevices` because the v1 CRD schema does not include it.

```bash
kubectl patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv --type=json \
  -p='[{"op":"add","path":"/spec/permittedHostDevices",
        "value":{"pciHostDevices":[
          {"pciDeviceSelector":"<gpu-pci-id>","resourceName":"nvidia.com/gpu"},
          {"pciDeviceSelector":"<nvswitch-pci-id>","resourceName":"nvidia.com/nvswitch"}
        ]}}]'
```

If there are no NVSwitches, omit the second entry:

```bash
kubectl patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv --type=json \
  -p='[{"op":"add","path":"/spec/permittedHostDevices",
        "value":{"pciHostDevices":[
          {"pciDeviceSelector":"<gpu-pci-id>","resourceName":"nvidia.com/gpu"}
        ]}}]'
```

Verify the node advertises capacity:

```bash
oc describe node <node-hostname> | grep "nvidia.com"
# Expected:
#   nvidia.com/gpu:      <count>
#   nvidia.com/nvswitch: <count>
```

### 5.3 Create the VM

> **CPU pinning:** If you configured CPU Manager in Part 2B, add `dedicatedCpuPlacement: true`
> and `isolateEmulatorThread: true` to the `domain.cpu` block below. Without these fields the
> VM still works but vCPUs are not pinned to exclusive host CPUs.

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: gpu-vm
  namespace: gpu-vms
spec:
  runStrategy: Always
  dataVolumeTemplates:
  - metadata:
      name: gpu-vm-disk
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
        kubevirt.io/vm: gpu-vm
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
          # Repeat one entry per GPU — each entry claims one device
          - name: gpu-0
            deviceName: nvidia.com/gpu
          - name: gpu-1
            deviceName: nvidia.com/gpu
          # Add nvidia.com/nvswitch entries here if NVSwitches are present
      networks:
      - name: default
        pod: {}
      volumes:
      - name: rootdisk
        dataVolume:
          name: gpu-vm-disk
      - name: cloudinit
        cloudInitNoCloud:
          userData: |
            #cloud-config
            user: ubuntu
            password: ubuntu
            chpasswd:
              expire: false
            ssh_pwauth: true
            ssh_authorized_keys:
            - <ssh-public-key>
```

```bash
oc new-project gpu-vms
oc apply -f gpu-vm.yaml

oc get datavolume gpu-vm-disk -n gpu-vms -w
# Wait for: PHASE=Succeeded

oc get vmi gpu-vm -n gpu-vms -w
# Wait for: PHASE=Running
```

### 5.4 Access the VM

```bash
# Format: <user>@vm/<vmname>/<namespace>
virtctl ssh ubuntu@vm/gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'
```

### 5.5 Install NVIDIA driver inside the VM (Ubuntu 24.04 example)

```bash
# Inside the VM
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-cuda.gpg
echo "deb [signed-by=/usr/share/keyrings/nvidia-cuda.gpg] \
  https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /" \
  | sudo tee /etc/apt/sources.list.d/nvidia-cuda.list

sudo apt-get update
sudo apt-get install -y linux-headers-$(uname -r)
# Install open kernel modules (required for Hopper/Blackwell GPUs)
sudo apt-get install -y nvidia-open-<driver-major>

# Auto-load at boot
echo nvidia | sudo tee /etc/modules-load.d/nvidia.conf

sudo reboot
```

After reboot:

```bash
nvidia-smi
```

#### NVSwitch / Fabric Manager (SXM form-factor GPUs)

If the GPU uses NVSwitch interconnects (H100 SXM, H200 SXM, etc.), install Fabric
Manager inside the VM. The FM version must exactly match the driver.

```bash
DRIVER_VER=$(cat /proc/driver/nvidia/version | awk '{print $8}')
sudo apt-get install -y nvidia-fabricmanager=${DRIVER_VER}-1ubuntu1
sudo systemctl enable --now nvidia-fabricmanager
```

Expected FM log output:
```
Connected to 1 node.
Successfully configured all the available NVSwitches to route GPU NVLink traffic.
```

### 5.6 Verify

```bash
# Inside the VM
lspci | grep -i nvidia     # GPUs and NVSwitches must appear as PCI devices
nvidia-smi                 # All GPUs listed
nvcc --version             # CUDA toolchain (if cuda-toolkit installed)
```

---

## Part 6 — GPU VM Passthrough: Approach B (GPU Operator Managed)

In this approach the NVIDIA GPU Operator manages the host-side driver and VFIO
binding. The operator runs in **sandbox workload mode**, which means it:

1. Loads the NVIDIA driver on the host (does **not** leave GPUs on `vfio-pci`)
2. Runs a `vfioManager` component that rebinds GPUs from `nvidia` to `vfio-pci`
   for VMs on demand, while still making CUDA available to host-side containers

This mode is incompatible with the pure VFIO approach from Part 5.
Do **not** apply the `vfio.conf` modprobe MachineConfig (Part 2.2) if using this approach.

### 6.1 Install the NVIDIA GPU Operator

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  channel: v24.9          # use the latest stable channel for your OCP version
  installPlanApproval: Automatic
```

```bash
oc apply -f gpu-operator-install.yaml
oc get csv -n nvidia-gpu-operator -w
# Wait for: PHASE=Succeeded
```

### 6.2 Create a ClusterPolicy with sandbox workload mode enabled

The key settings for VM passthrough:

| Field | Value | Reason |
|-------|-------|--------|
| `sandboxWorkloads.enabled` | `true` | Activates the VM passthrough mode |
| `sandboxWorkloads.defaultWorkload` | `vm-passthrough` | Ensures the node is configured for VM use |
| `vfioManager.enabled` | `true` | Manages vfio-pci binding per-VM |
| `driver.enabled` | `true` | Loads nvidia.ko on the host (required for vfioManager) |

```yaml
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
  sandboxWorkloads:
    enabled: true
    defaultWorkload: vm-passthrough
  driver:
    enabled: true
  vfioManager:
    enabled: true
  sandboxDevicePlugin:
    enabled: true
  devicePlugin:
    enabled: true
  dcgm:
    enabled: true
  dcgmExporter:
    enabled: true
  gfd:
    enabled: true
  mig:
    strategy: single
  nodeStatusExporter:
    enabled: true
  toolkit:
    enabled: true
```

```bash
oc apply -f gpu-cluster-policy.yaml

# Watch operator components come up (several minutes)
oc get pods -n nvidia-gpu-operator -w
```

### 6.3 Verify node workload configuration label

The GPU Operator's Node Feature Discovery (NFD) and GFD components automatically
label each node based on the `ClusterPolicy` settings. With `sandboxWorkloads.enabled: true`
and `defaultWorkload: vm-passthrough`, the operator sets the workload label on nodes
during reconciliation — **you do not need to set it manually** under normal conditions.

Verify the label was applied by the operator:

```bash
oc get node <node-hostname> -o jsonpath='{.metadata.labels}' \
  | python3 -m json.tool | grep -i "workload\|sandbox"
# Look for a label indicating vm-passthrough mode
```

If the operator is fully reconciled but GPUs are still not binding to `vfio-pci`,
check the `vfioManager` daemonset pod logs:

```bash
oc logs -n nvidia-gpu-operator -l app=nvidia-vfio-manager --tail=50
```

> **Do not manually set** `nvidia.com/gpu.workload.config` — the GPU Operator
> overwrites manually-set labels during reconciliation, and setting an incorrect
> value can put the node into an inconsistent state.

### 6.4 Verify GPU Operator vfio-pci binding

In sandbox mode the GPU Operator's `vfioManager` binds GPUs to `vfio-pci`. Check:

```bash
oc debug node/<node-hostname> -- chroot /host sh -c "
  for dev in \$(lspci -d <gpu-pci-id>: -D | awk '{print \$1}'); do
    driver=\$(readlink /sys/bus/pci/devices/\$dev/driver 2>/dev/null | xargs basename 2>/dev/null || echo NONE)
    echo \"\$dev -> \$driver\"
  done"
# Expected: vfio-pci
```

### 6.5 Expose devices through HyperConverged

Same as the pure VFIO approach (Part 5.2) — add the GPU (and NVSwitch if present)
to `permittedHostDevices` via `v1beta1`:

```bash
kubectl patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv --type=json \
  -p='[{"op":"add","path":"/spec/permittedHostDevices",
        "value":{"pciHostDevices":[
          {"pciDeviceSelector":"<gpu-pci-id>","resourceName":"nvidia.com/gpu"}
        ]}}]'
```

### 6.6 Create the VM

The VM manifest is identical to the pure VFIO approach (Part 5.3). The difference
is entirely on the host side — KubeVirt still uses `hostDevices` with
`nvidia.com/gpu` resource names regardless of which approach manages VFIO binding.

```bash
oc apply -f gpu-vm.yaml

oc get vmi gpu-vm -n gpu-vms -w
# Wait for: PHASE=Running
```

### 6.7 Install the NVIDIA driver inside the VM

Same steps as Part 5.5 — the driver runs inside the guest VM regardless of host mode.

### 6.8 Approach comparison

| Aspect | Pure VFIO | GPU Operator Managed |
|--------|-----------|---------------------|
| Host NVIDIA driver | Not loaded | Loaded |
| VFIO binding managed by | MachineConfig (`modprobe.d`) | GPU Operator `vfioManager` |
| Host CUDA containers | Not possible | Possible (if containers scheduled alongside VMs) |
| NVSwitch support | Manual (add NVSwitch PCI ID to MachineConfig and HCO) | Via GPU Operator `sandboxDevicePlugin` |
| Complexity | Lower | Higher (Operator manages lifecycle) |
| Conflict risk | None (no nvidia driver on host) | Must ensure `sandboxWorkloads.enabled=true` |

---

## Part 7 — SSH Access to VMs

### 7.1 virtctl ssh (direct, requires proper CNV networking)

```bash
# Syntax: <user>@vm/<vmname>/<namespace>
virtctl ssh ubuntu@vm/gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

# Run a command non-interactively
virtctl ssh ubuntu@vm/gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no' \
  -c 'nvidia-smi'
```

> `virtctl ssh` proxies through `virt-api` → `virt-handler` → VM using a WebSocket
> tunnel over the Kubernetes API. It requires the virt-handler pod to have a
> network path to the VM's guest IP (`10.0.2.2` in masquerade mode).

### 7.2 NodePort SSH (reliable fallback)

If `virtctl ssh` is unavailable or broken, expose SSH via a NodePort Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: gpu-vm-ssh
  namespace: gpu-vms
spec:
  type: NodePort
  selector:
    vm.kubevirt.io/name: gpu-vm
  ports:
  - name: ssh
    port: 22
    targetPort: 22
    nodePort: 30022
    protocol: TCP
```

```bash
ssh -p 30022 ubuntu@<node-ip>
```

---

## Part 8 — Adding Worker Nodes

### 8.1 Generate a worker agent ISO

> **OCP version note:** For OCP 4.14 and earlier, adding workers to an existing SNO
> cluster requires a separate procedure using `openshift-install agent create add-nodes-image`
> and the cluster's infrastructure files (not just the kubeconfig). For OCP 4.15+, the
> agent-based installer supports adding workers directly. Verify the exact procedure for
> your version in the [OpenShift documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/).

```bash
mkdir -p ~/sno/worker-install-dir

cat > ~/sno/worker-install-dir/agent-config.yaml << 'EOF'
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: <cluster-name>
hosts:
- hostname: <worker-hostname>
  role: worker
  interfaces:
  - name: <worker-management-nic>
    macAddress: "<worker-management-mac>"
  networkConfig:
    interfaces:
    - name: <worker-management-nic>
      type: ethernet
      state: up
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: <worker-management-ip>
          prefix-length: 24
    dns-resolver:
      config:
        server:
        - <dns-server>
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: <gateway>
        next-hop-interface: <worker-management-nic>
        table-id: 254
EOF

cp ~/sno/install-dir/auth/kubeconfig ~/sno/worker-install-dir/
openshift-install agent create image --dir ~/sno/worker-install-dir/
```

Boot the worker from the generated ISO. It auto-discovers and joins the cluster.

```bash
oc get nodes -w
# Expected: <worker-hostname>  Ready  worker
```

### 8.2 Apply worker MachineConfigs for IOMMU and VFIO

Duplicate the MachineConfigs from Parts 2.1 and 2.2 with `role: worker` labels.

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

```bash
oc apply -f 100-worker-iommu.yaml
oc apply -f 100-worker-vfio-pci-gpu.yaml

oc get machineconfigpool worker -w
# Wait for: UPDATED=True  UPDATING=False  DEGRADED=False
```

### 8.3 Add per-worker LVMS storage

Add a new device class to the existing LVMCluster using the worker's disk by-id path:

```bash
# Find the stable by-id path on the worker
oc debug node/<worker-hostname> -- chroot /host \
  sh -c "ls -la /dev/disk/by-id/nvme-* | grep -v part"

# Add a new device class
oc patch lvmcluster lvmcluster -n openshift-storage --type=json -p='[
  {"op":"add","path":"/spec/storage/deviceClasses/-","value":{
    "name": "vmstorage-worker",
    "deviceSelector": {
      "paths": ["/dev/disk/by-id/<worker-disk-id>"]
    },
    "thinPoolConfig": {"name": "thin-pool", "sizePercent": 90, "overprovisionRatio": 10},
    "fstype": "xfs"
  }}
]'
```

Create a StorageClass with `allowedTopologies` so CDI provisions PVCs on the correct node:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: lvms-vmstorage-worker-immediate
provisioner: topolvm.io
parameters:
  csi.storage.k8s.io/fstype: xfs
  topolvm.io/device-class: vmstorage-worker
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
allowedTopologies:
- matchLabelExpressions:
  - key: topology.topolvm.io/node
    values:
    - <worker-hostname>
```

---

## Troubleshooting

### HCO removes permittedHostDevices within seconds

Cause: patching via the default `v1` API, which doesn't store the field.
Always use `v1beta1`:

```bash
kubectl patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv ...
```

Verify what is actually stored:

```bash
kubectl get hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv -o jsonpath='{.spec.permittedHostDevices}' | python3 -m json.tool
```

### GPUs not bound to vfio-pci after reboot (GPU Operator conflict)

The GPU Operator's `driver` or `vfioManager` component rebinds GPUs. Fix for pure
VFIO approach: disable both in the ClusterPolicy:

```bash
oc patch clusterpolicy gpu-cluster-policy \
  --type=merge -p '{"spec":{"driver":{"enabled":false},"vfioManager":{"enabled":false}}}'
```

### `cuInit()` error 802 (CUDA_ERROR_SYSTEM_NOT_READY)

Fabric Manager is not running or failed. Required for SXM GPUs with NVSwitch.
Check inside the VM:

```bash
sudo systemctl status nvidia-fabricmanager
sudo journalctl -u nvidia-fabricmanager --no-pager -n 20
```

FM logs must show: `Connected to 1 node` and `Successfully configured all the available NVSwitches`.

### NVMe device path changes after MCO reboot

Cause: NVMe enumeration is non-deterministic. `/dev/nvme0n1` before reboot may
become `/dev/nvme4n1` after. Always use `by-id` paths in LVMCluster device selectors.

Fix:

```bash
oc patch lvmcluster lvmcluster -n openshift-storage --type=json -p='[
  {"op":"replace",
   "path":"/spec/storage/deviceClasses/0/deviceSelector/paths/0",
   "value":"/dev/disk/by-id/<stable-id>"}
]'
```

### CDI scratch PVC provisioned on the wrong node

Cause: StorageClass without `allowedTopologies` — CSI provisioner picks any node.

Fix: add `allowedTopologies` to pin the StorageClass to the correct node (see Part 8.3).

### VM not scheduling (insufficient `nvidia.com/gpu` resources)

```bash
# Check node resource capacity
oc describe node <node-hostname> | grep "nvidia.com"

# Verify virt-handler device-plugin is running
oc get pods -n openshift-cnv -l kubevirt.io=virt-handler

# Check GPU is bound to vfio-pci
oc debug node/<node-hostname> -- chroot /host lspci -k | grep -A2 <gpu-pci-id>
```

### CDI orphan ConfigMap blocks deployment

If CDI components (other than `cdi-operator`) never appear and the operator log
repeats `"Orphan object exists"`:

```bash
oc delete configmap cdi-apiserver-signer-bundle -n openshift-cnv
```

---

## Quick Reference

```bash
# Cluster health
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
oc get vm,vmi,datavolume -n gpu-vms

# GPU capacity on node
oc describe node <node-hostname> | grep "nvidia.com"

# HCO permittedHostDevices (use v1beta1)
kubectl get hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged \
  -n openshift-cnv -o jsonpath='{.spec.permittedHostDevices}' | python3 -m json.tool

# GPU Operator pods
oc get pods -n nvidia-gpu-operator

# GPU Operator sandbox mode status
oc get clusterpolicy gpu-cluster-policy \
  -o jsonpath='{.spec.sandboxWorkloads}' | python3 -m json.tool

# GPU driver binding on node
oc debug node/<node-hostname> -- chroot /host sh -c "
  for dev in \$(lspci -d <gpu-pci-id>: -D | awk '{print \$1}'); do
    driver=\$(readlink /sys/bus/pci/devices/\$dev/driver 2>/dev/null \
              | xargs basename 2>/dev/null || echo NONE)
    echo \"\$dev -> \$driver\"
  done"

# VM lifecycle
virtctl start   gpu-vm -n gpu-vms
virtctl stop    gpu-vm -n gpu-vms
virtctl restart gpu-vm -n gpu-vms

# VM SSH (virtctl)
virtctl ssh ubuntu@vm/gpu-vm/gpu-vms \
  --known-hosts='' -t '-o StrictHostKeyChecking=no'

# VM SSH (NodePort fallback)
ssh -p 30022 ubuntu@<node-ip>

# MCO pause/unpause during VM workloads
oc patch machineconfigpool master --type=merge -p '{"spec":{"paused":true}}'
oc patch machineconfigpool master --type=merge -p '{"spec":{"paused":false}}'
```
