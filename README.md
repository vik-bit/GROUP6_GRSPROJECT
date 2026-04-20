
````markdown
# CNI Benchmark Project

This project benchmarks Kubernetes networking using three Container Network Interface (CNI) plugins:

- **Calico**
- **Flannel**
- **Cilium** (currently under testing)

Microservices are deployed on a local **Kind** cluster, and load is generated via **Locust**.  
Performance metrics are recorded in CSV files for graphing and analysis.

---

## Repository Setup

To get started, clone the project repository:

```bash
git clone https://github.com/vik-bit/GROUP6_GRSPROJECT.git
cd GROUP6_GRSPROJECT
````

---

### Set Executable Permissions on Setup Scripts (First Time Only)

> It is **not mandatory** to run these scripts — data can be accessed directly from the CSV files.
> However, if you want to see the full setup process or tweak configurations, follow these steps:

```bash
cd scripts

# Calico setup
chmod +x ./calicosetup.sh
sudo ./calicosetup.sh

# Cilium setup (under testing)
chmod +x ./ciliumsetup.sh
sudo ./ciliumsetup.sh

# Flannel setup
chmod +x ./flannelsetup.sh
sudo ./flannelsetup.sh

# Metrics collector (permission change only, integrated in setup scripts)
chmod +x ./metrics.sh
```

> **Note:** Use `sudo` as scripts require privileges to configure networking, system modules, Docker, and Kubernetes.
> The metrics collector is already included in the setup scripts — do not run it separately.

---

## Running Load Tests

After cluster setup and microservices deployment, load tests are executed via **Locust**.

Load test results are appended to CSV files in the project root:

* `calicoresults.csv` — benchmark data for **Calico**
* `flannelresults.csv` — benchmark data for **Flannel**
* `ciliumresults.csv` — benchmark data for **Cilium**

These CSV files contain **real measured performance metrics** for graphing (using Python) and detailed analysis.
All graphing scripts (`.py`) should be placed inside the `plots/` folder.

---

## Metrics Collected

| Metric                      | Description                                       |
| --------------------------- | ------------------------------------------------- |
| **Timestamp**               | When the test was executed                        |
| **Users**                   | Number of simulated concurrent users              |
| **Requestpersec (RPS)**     | Throughput — Requests per second handled          |
| **Percentile95_latency_ms** | 95th percentile of response latency (in ms)       |
| **CPU_pods**                | Aggregate CPU usage of pods                       |
| **Memory_pods**             | Aggregate memory usage of pods (MB)               |
| **CPU_nodes**               | CPU usage on nodes                                |
| **Memory_nodes**            | Memory usage on nodes (MB)                        |
| **Ping_intra_ms**           | Latency inside a node (pod-to-pod same node)      |
| **Ping_inter_ms**           | Latency across nodes (pod-to-pod different nodes) |
| **Bandwidth_mbps**          | Network throughput in Mbps                        |

---

## Notes

* Setup scripts **clean up old Kind clusters and Docker artifacts** before a fresh deployment.

* Prometheus and Grafana monitoring stacks are deployed via **Helm** in the `monitoring` namespace.

* Port forwarding is configured automatically:

  * Prometheus → `localhost:9090`
  * Grafana → `localhost:3000`

* You can customize user loads and test durations directly within the setup scripts.

---

## Contribution

Contributions and improvements are welcome! You can help with:

* Adding more CNIs or CNI versions
* Enhancing metrics scripts or automation
* Adding automated graph/report generation
* Improving documentation and user experience

Please clearly document any additions or changes.

---

## Happy Benchmarking! 🚀

> Leverage this setup to evaluate CNI performance, visualize trends, and understand Kubernetes network behavior in small to medium clusters.


