# Namespace-Based Microservice Benchmarking

A Linux namespace-based networking implementation for microservice chain benchmarking. This replaces the Kind/Kubernetes setup with pure Linux primitives (`ip netns`, `veth`, bridges, routing) while preserving the same experimental goals.

> **📖 For detailed instructions on running experiments, viewing results, and analysis:**
> **See [EXPERIMENT_GUIDE.md](EXPERIMENT_GUIDE.md)**

---

## Architecture

```
                            HOST
                             │
                        ┌────┴────┐
                        │ns-client│ (Locust target / curl test)
                        │10.0.1.10│
                        └────┬────┘
                             │ veth
                      ┌──────┴──────┐
            Node 1    │   br-node1  │ (10.0.1.0/24)
                      │ Linux Bridge│
                      ├──────┬──────┤
                      │      │      │
                 ┌────┴──┐ ┌┴──────┐
                 │ns-svc-a│ │ns-svc-b│
                 │10.0.1.2│ │10.0.1.3│
                 │ :8080  │ │ :8080  │
                 └────────┘ └───────┘
                      │
                route │  via host (IP forwarding)
                      │
                      ┌──────┴──────┐
            Node 2    │   br-node2  │ (10.0.2.0/24)
                      │ Linux Bridge│
                      ├─────────────┤
                      │             │
                 ┌────┴───┐
                 │ns-svc-c │
                 │10.0.2.2 │
                 │ :8080   │
                 └─────────┘

  Request Flow: Client → A (10.0.1.2) → B (10.0.1.3) → C (10.0.2.2)
  Response:     "-> -> service-c"
```

---

## Kubernetes → Namespace Mapping

| Kubernetes Concept    | Namespace Equivalent                         |
|-----------------------|----------------------------------------------|
| Pod                   | Network namespace (`ip netns`)               |
| Node                  | Linux bridge grouping namespaces             |
| ClusterIP Service     | Direct IP addressing (static IPs)            |
| CNI (Flannel)         | VXLAN overlay between bridges                |
| CNI (Calico)          | iptables FORWARD chain rules                 |
| `kubectl port-forward`| Host veth into client namespace              |
| Container image       | Statically-compiled C binary                 |
| `kubectl exec`        | `ip netns exec <ns> ...`                     |
| Pod-to-Pod networking | veth pairs through Linux bridges             |

---

## Key Differences from Kind Implementation

| Aspect               | Kind/K8s                          | Namespace Implementation               |
|-----------------------|-----------------------------------|----------------------------------------|
| **Runtime**           | Docker + containerd               | Native binaries in namespaces          |
| **Language**          | Go (server.go)                    | C (service.c)                          |
| **Networking**        | CNI plugins (Flannel/Calico)      | ip netns + veth + bridges              |
| **Service discovery** | DNS (e.g., `http://service-b`)    | Static IPs (e.g., `http://10.0.1.3`)  |
| **Monitoring**        | kube-prometheus-stack (Helm)      | node_exporter + process-exporter       |
| **Load testing**      | Locust → kubectl port-forward     | Locust → direct bridge IP              |
| **Overhead**          | Docker + kubelet + kube-proxy     | Minimal (just Linux kernel)            |

---

## Prerequisites

```bash
# Required
sudo apt install -y gcc make curl jq iperf3 bc

# For load testing
pip install locust

# For monitoring
# Docker (for Prometheus + Grafana containers)
sudo apt install -y docker.io
```

---

## Quick Start

### 1. Setup Topology

```bash
cd namespace-implementation/scripts

# Baseline mode (bridge + static routing)
sudo ./setup_topology.sh --mode bridge

# Or with VXLAN overlay (Flannel-like)
sudo ./setup_topology.sh --mode vxlan

# Or with iptables rules (Calico-like)
sudo ./setup_topology.sh --mode iptables
```

### 2. Run Services

```bash
sudo ./run_services.sh
# Services start in background, chain test runs automatically
```

### 3. Test Manually

```bash
# From host
curl http://10.0.1.2:8080/
# Expected: -> -> service-c

# From client namespace
sudo ip netns exec ns-client curl http://10.0.1.2:8080/
```

### 4. Setup Monitoring (Optional)

```bash
sudo ./setup_monitoring.sh
# Prometheus: http://localhost:9090
# Grafana:    http://localhost:3000 (admin/admin)
```

### 5. Run Full Experiment

```bash
# Runs Locust at 50/100/200/300/400 users, collects metrics
sudo ./run_experiment.sh --mode bridge
# Results saved to: results/namespace_bridge_results.csv
```

### 6. Cleanup

```bash
sudo ./cleanup.sh
```

---

## File Structure

```
namespace-implementation/
├── scripts/
│   ├── setup_topology.sh      # Create namespaces, bridges, veths, routes
│   ├── run_services.sh        # Compile & launch C services in namespaces
│   ├── run_experiment.sh      # Full experiment orchestrator
│   ├── setup_monitoring.sh    # Prometheus + Grafana (Docker)
│   ├── metrics.sh             # Collect RPS, latency, CPU, memory, ping, bandwidth
│   └── cleanup.sh             # Tear down everything
├── src/
│   ├── service.c              # C HTTP server (chain-forwarding microservice)
│   └── Makefile               # Build static binary
├── configs/
│   ├── prometheus.yml         # Prometheus scrape configuration
│   └── process-exporter.yml   # Process exporter match rules
├── load-test/
│   └── locustfile.py          # Locust load test (same as Kind setup)
├── results/                   # CSV output files
└── README.md                  # This file
```

---

## Networking Modes

### Bridge (Default)
Standard Linux bridges with static routing through the host. Simplest and most transparent for debugging.

### VXLAN (Flannel-like)
Adds VXLAN tunnel interfaces between `br-node1` and `br-node2`, simulating how Flannel creates overlay networks between Kubernetes nodes.

### iptables (Calico-like)
Adds `iptables` FORWARD chain rules that explicitly allow/deny traffic between subnets, simulating Calico's network policy enforcement. Dropped packets are logged to dmesg.

---

## Metrics Collected

Same CSV format as the Kind implementation:

| Metric              | Source                                    |
|---------------------|-------------------------------------------|
| `timestamp`         | System clock                              |
| `users`             | Locust user count                         |
| `rps`               | Locust stats CSV                          |
| `p95_latency_ms`    | Locust stats CSV                          |
| `cpu_pods`          | Prometheus (process-exporter)             |
| `memory_pods`       | Prometheus (process-exporter)             |
| `cpu_nodes`         | Prometheus (node_exporter)                |
| `memory_nodes`      | Prometheus (node_exporter)                |
| `ping_intra_ms`     | `ip netns exec` ping (svc-a → svc-b)     |
| `ping_inter_ms`     | `ip netns exec` ping (svc-a → svc-c)     |
| `bandwidth_mbps`    | iperf3 between namespaces                 |

---

## Troubleshooting

**Ping between nodes fails:**
```bash
# Check IP forwarding
sysctl net.ipv4.ip_forward
# Should be 1

# Check bridge IPs
ip addr show br-node1
ip addr show br-node2

# Check namespace routes
sudo ip netns exec ns-svc-a ip route
```

**Service chain returns error:**
```bash
# Test each service individually
sudo ip netns exec ns-svc-c curl -s http://10.0.2.2:8080/
sudo ip netns exec ns-svc-b curl -s http://10.0.1.3:8080/
sudo ip netns exec ns-svc-a curl -s http://10.0.1.2:8080/
```

**Locust can't reach service:**
```bash
# Verify host can reach service-a
curl -s http://10.0.1.2:8080/
# If this fails, check bridge is up: ip link show br-node1
```
