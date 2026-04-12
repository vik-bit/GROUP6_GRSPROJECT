# Experiment Guide: Running and Analyzing Results

This guide explains how to run experiments, where results are stored, and how to analyze them using Prometheus, Grafana, and the CSV outputs.

---

## Quick Reference: Where Everything Lives

| What | Location |
|------|----------|
| **Raw CSV results** | `namespace-implementation/results/namespace_<mode>_results.csv` |
| **Locust stats** | `namespace-implementation/load-test/locust_stats_stats.csv` |
| **Service logs** | `/tmp/ns-svc-a.log`, `/tmp/ns-svc-b.log`, `/tmp/ns-svc-c.log` |
| **Prometheus UI** | http://localhost:9090 |
| **Grafana UI** | http://localhost:3000 (admin/admin) |
| **node_exporter metrics** | http://localhost:9100/metrics |
| **process-exporter metrics** | http://localhost:9256/metrics |

---

## Running a Full Experiment

### Option 1: Automated (Recommended)

The `run_experiment.sh` script does everything automatically:

```bash
cd namespace-implementation/scripts

# Run with bridge mode (default baseline)
sudo ./run_experiment.sh --mode bridge

# Run with VXLAN overlay (Flannel-like)
sudo ./run_experiment.sh --mode vxlan

# Run with iptables rules (Calico-like)
sudo ./run_experiment.sh --mode iptables

# Skip monitoring if you just want quick results
sudo ./run_experiment.sh --mode bridge --skip-monitoring
```

**What it does automatically:**
1. Cleans up any previous topology
2. Sets up namespaces, bridges, and routing
3. Compiles and starts all 3 services
4. Deploys Prometheus + Grafana monitoring
5. Runs Locust at user levels: **50 → 100 → 200 → 300 → 400**
6. Collects metrics after each level
7. Saves results to `results/namespace_<mode>_results.csv`

### Option 2: Manual (Step by Step)

```bash
cd namespace-implementation/scripts

# Step 1: Setup
sudo ./cleanup.sh
sudo ./setup_topology.sh --mode bridge

# Step 2: Start services (run in background with &, or in a separate terminal)
sudo ./run_services.sh &

# Step 3: Monitoring (optional)
sudo ./setup_monitoring.sh

# Step 4: Run Locust manually
cd ../load-test
locust -f locustfile.py --host=http://10.0.1.2:8080 --headless \
    -u 100 -r 10 --run-time 1m --csv=locust_stats

# Step 5: Collect metrics
cd ../scripts
sudo ./metrics.sh 100

# Step 6: Cleanup when done
sudo ./cleanup.sh
```

---

## Understanding the Results CSV

After an experiment, your CSV looks like this:

```
timestamp,users,rps,p95_latency_ms,cpu_pods,memory_pods,cpu_nodes,memory_nodes,ping_intra_ms,ping_inter_ms,bandwidth_mbps
2026-04-13 01:50:00,50,32.45,5,0.0012,1.25,3.5,1780.0,0.080,0.140,42000.000
```

| Column | What It Measures | Source |
|--------|-----------------|--------|
| `timestamp` | When the test was run | System clock |
| `users` | Number of simulated concurrent users | Locust config |
| `rps` | Requests per second handled | Locust stats CSV |
| `p95_latency_ms` | 95th percentile response time | Locust stats CSV |
| `cpu_pods` | Total CPU (cores) used by service processes | Prometheus (process-exporter) |
| `memory_pods` | Total memory (MiB) used by service processes | Prometheus (process-exporter) |
| `cpu_nodes` | Host CPU usage (%) | Prometheus (node_exporter) |
| `memory_nodes` | Host memory used (MiB) | Prometheus (node_exporter) |
| `ping_intra_ms` | Latency within same bridge (A↔B) | `ip netns exec` ping |
| `ping_inter_ms` | Latency across bridges (A↔C) | `ip netns exec` ping |
| `bandwidth_mbps` | Network throughput between namespaces | iperf3 |

---

## Analyzing with Prometheus

### Access
Open http://localhost:9090 in your browser.

### Useful Queries

**Service CPU usage (per process):**
```promql
rate(namedprocess_namegroup_cpu_seconds_total{groupname=~".*service.*"}[1m])
```

**Service memory usage (MiB):**
```promql
namedprocess_namegroup_memory_bytes{groupname=~".*service.*",memtype="resident"} / 1024 / 1024
```

**Host CPU usage (%):**
```promql
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)
```

**Host memory usage (MiB):**
```promql
(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / 1024 / 1024
```

**Network traffic (bytes/sec):**
```promql
rate(node_network_receive_bytes_total{device=~"br-node.*|veth-.*"}[1m])
```

---

## Analyzing with Grafana

### Access
Open http://localhost:3000 (login: admin/admin).

### Setting Up a Dashboard

1. Click **"+"** → **"New Dashboard"** → **"Add visualization"**
2. Select **"Prometheus"** as data source
3. Paste any of the PromQL queries above
4. Recommended panels:
   - **Time series** for CPU/memory over time
   - **Gauge** for current values
   - **Stat** for key metrics at a glance

### Suggested Dashboard Layout

| Panel | Query | Visualization |
|-------|-------|---------------|
| Service CPU | `rate(namedprocess_namegroup_cpu_seconds_total{...}[1m])` | Time series |
| Service Memory | `namedprocess_namegroup_memory_bytes{...} / 1024 / 1024` | Time series |
| Host CPU % | `100 - avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100` | Gauge |
| Network I/O | `rate(node_network_receive_bytes_total{device=~"br-.*"}[1m])` | Time series |

---

## Side-by-Side Comparison with Kind

To compare namespace results with the Kind/K8s results:

```
# Kind results (already in repo root)
calicoresults.csv
flannelresults.csv
ciliumresults.csv

# Namespace results (after experiments)
namespace-implementation/results/namespace_bridge_results.csv
namespace-implementation/results/namespace_vxlan_results.csv
namespace-implementation/results/namespace_iptables_results.csv
```

Both use the **same CSV column format**, so you can directly compare using the plotting scripts in `plots/` or write new ones.

### Example Python Comparison Script

```python
import pandas as pd
import matplotlib.pyplot as plt

# Load results
flannel = pd.read_csv('../../flannelresults.csv')
ns_bridge = pd.read_csv('../results/namespace_bridge_results.csv')

# Compare RPS
plt.figure(figsize=(10, 6))
plt.plot(flannel['users'], flannel['rps'], 'o-', label='Flannel (Kind)')
plt.plot(ns_bridge['users'], ns_bridge['rps'], 's-', label='Bridge (Namespace)')
plt.xlabel('Concurrent Users')
plt.ylabel('Requests/sec')
plt.title('Throughput: Kind vs Namespace')
plt.legend()
plt.grid(True)
plt.savefig('../results/comparison_rps.png')
plt.show()
```

---

## Running All 3 Modes for Comparison

```bash
cd namespace-implementation/scripts

# Mode 1: Bridge (baseline)
sudo ./run_experiment.sh --mode bridge

# Mode 2: VXLAN (Flannel-like overlay)
sudo ./run_experiment.sh --mode vxlan

# Mode 3: iptables (Calico-like filtering)
sudo ./run_experiment.sh --mode iptables
```

Results will be saved as separate CSV files:
- `results/namespace_bridge_results.csv`
- `results/namespace_vxlan_results.csv`
- `results/namespace_iptables_results.csv`

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Results CSV shows `NA` for CPU/memory | Prometheus may not be running. Run `sudo ./setup_monitoring.sh` first |
| Locust not found | Install: `pip install locust` |
| Service chain returns error | Run `sudo ./diagnose.sh` to check connectivity |
| Grafana shows no data | Check Prometheus targets at http://localhost:9090/targets |
| iperf3 bandwidth is NA | Install: `sudo apt install iperf3` |
