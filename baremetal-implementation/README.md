# Bare-Metal Kubernetes Implementation

Single-node kubeadm Kubernetes cluster for CNI benchmarking, running directly on the host OS (CachyOS/Arch Linux).

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Host Machine (CachyOS)                │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │            kubeadm Control Plane                  │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │   │
│  │  │ kube-api │ │ etcd     │ │ controller-mgr   │ │   │
│  │  └──────────┘ └──────────┘ └──────────────────┘ │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
│  ┌──────────── CNI (Flannel/Calico/Cilium) ──────────┐  │
│  │                                                    │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐  │  │
│  │  │ Service A  │→ │ Service B  │→ │ Service C  │  │  │
│  │  │ :8080      │  │ :8080      │  │ :8080      │  │  │
│  │  └────────────┘  └────────────┘  └────────────┘  │  │
│  │                                                    │  │
│  └────────────────────────────────────────────────────┘  │
│                                                         │
│  ┌──────────────────┐                                   │
│  │   containerd      │  (container runtime)             │
│  └──────────────────┘                                   │
└─────────────────────────────────────────────────────────┘
```

## Why "Bare Metal"?

| Aspect | Bare Metal (this) | Kind | Namespace |
|--------|-------------------|------|-----------|
| Kubernetes | kubeadm on host | Docker containers | None |
| Container runtime | containerd (direct) | Docker-in-Docker | N/A (native processes) |
| Network stack | Host kernel + CNI | Docker network + CNI | veth + bridges |
| Overhead | Minimal (no virtualization) | Docker layer overhead | None (pure Linux) |
| Pod scheduling | Real kubelet | Simulated nodes | N/A |

**Key difference from Kind**: Kind runs Kubernetes nodes as Docker containers, adding a virtualization layer. This setup runs kubeadm directly on the host with containerd, eliminating that overhead for more accurate CNI performance measurement.

**Key difference from namespace setup**: The namespace implementation uses raw Linux networking primitives without Kubernetes. This setup uses the full Kubernetes stack (kubelet, kube-proxy, CNI) to measure the real overhead of orchestration.

## Prerequisites

- **OS**: CachyOS / Arch Linux (x86_64)
- **Kernel**: 5.x+ (6.x recommended)
- **RAM**: 4GB+ (8GB recommended)
- **Disk**: 10GB+ free
- **Access**: Root / sudo
- **Docker**: Required for building container images (or nerdctl)

## Quick Start

### 1. Set up the cluster

```bash
sudo bash scripts/setup_cluster.sh
```

### 2. Install a CNI

```bash
# Choose one:
bash scripts/install_flannel.sh
bash scripts/install_calico.sh
bash scripts/install_cilium.sh
```

### 3. Deploy workloads

```bash
bash scripts/deploy_workload.sh
```

### 4. Test the service chain

```bash
curl http://localhost:8080
# Expected: -> -> service-c
```

### 5. Run experiments

```bash
# Single CNI:
sudo bash scripts/run_experiment.sh flannel

# All CNIs (sequential reset + test):
sudo bash scripts/run_experiment.sh all
```

## Switching CNIs

To switch between CNIs, you must reset and reinitialize the cluster:

```bash
# 1. Reset
sudo bash scripts/reset_cluster.sh

# 2. Setup fresh cluster
sudo bash scripts/setup_cluster.sh

# 3. Install new CNI
bash scripts/install_calico.sh   # or flannel, cilium

# 4. Redeploy
bash scripts/deploy_workload.sh
```

The `run_experiment.sh` script automates this entire cycle.

## Directory Structure

```
baremetal-implementation/
├── scripts/
│   ├── setup_cluster.sh      # Initialize kubeadm cluster
│   ├── reset_cluster.sh      # Tear down cluster + cleanup
│   ├── install_flannel.sh    # Install Flannel CNI
│   ├── install_calico.sh     # Install Calico CNI
│   ├── install_cilium.sh     # Install Cilium CNI
│   ├── deploy_workload.sh    # Build image + deploy A→B→C
│   ├── run_experiment.sh     # Full experiment pipeline
│   └── metrics.sh            # Collect performance metrics
├── manifests/
│   ├── service-a.yaml        # Deployment + Service
│   ├── service-b.yaml        # Deployment + Service
│   └── service-c.yaml        # Deployment + Service
├── configs/
│   ├── containerd-config.toml
│   ├── kubeadm-config.yaml
│   └── sysctl-k8s.conf
├── results/                   # Experiment output (CSV)
└── README.md
```

## Single-Node Limitations

Since this runs on a single physical machine:

- **No inter-node traffic**: All pod-to-pod communication is intra-node. CNI overlay networking (VXLAN, IP-in-IP) may behave differently than in multi-node clusters.
- **No network hop simulation**: Packets don't traverse physical network hardware between nodes.
- **Shared resources**: The control plane and workloads compete for the same CPU/memory.
- **Still valuable**: Measures the true overhead of the CNI data plane (iptables rules, eBPF programs, routing table lookups) without Docker virtualization artifacts.

## Results

After running experiments, results are saved in `results/`:

| File | Description |
|------|-------------|
| `flannel_results.csv` | Flannel benchmark results |
| `calico_results.csv` | Calico benchmark results |
| `cilium_results.csv` | Cilium benchmark results |

CSV columns: `timestamp, users, rps, p95_latency_ms, cpu_pods, memory_pods_mib, cpu_nodes_pct, memory_nodes_mib, ping_intra_ms, bandwidth_mbps`

## Troubleshooting

### Node stuck in NotReady
```bash
# Check kubelet logs
journalctl -u kubelet -f
# Check CNI pods
kubectl get pods -A
```

### Image pull errors
```bash
# Verify image is in containerd
crictl images | grep microservice
```

### Reset everything
```bash
sudo bash scripts/reset_cluster.sh --force
```
