# VM Implementation — CNI Benchmark 

This folder contains CNI benchmarking experiments Calico and  Flannel in a VM-setup of a control plane and a worker Node .

| Component |  Setting  |
| --- | --- |
| Nodes | 2 (1 Master, 1 Worker) | 
| CPU | Master: 2 vCPUs, Worker 1 vCPU | 
| RAM | Master: 3 GB, Worker 2 GB |
| Disk | 30 GB | 
| OS | Ubuntu 22.04  | 
|Network| NAT and Host only Adapter|

Note: NAT for vms for communicating with host OS , Host Only Adapter for the stable cluster communication.

## Folder overview

- `k8s_manifests/` — Kubernetes manifests used to deploy the microservices for testing.
  - `service-a.yaml`, `service-b.yaml`, `service-b-svc.yaml`, `service-c.yaml`, `service-c-svc.yaml`
- `load-test/` — Locust load-test configuration and results (contains `locustfile.py` and CSV stats).
- `microservieces/` — microservice code and `Dockerfile` used to build the test images.
- `plots/` — plotting scripts used to generate graphs from results of calico and flannel cni `calicovsflannel.py`.
- `scripts/` — helper scripts  `metrics.sh` used to collect runtime metrics.
- `results.csv` — consolidated results from Performance metrics(bandwidth,P95 latency, ).
## Quick prerequisites

- `kubectl` configured to talk to  VM cluster.
- `locust` for loadtesting.


## Commands used

Checking cluster state:

```bash
kubectl get nodes
kubectl get pods -A
```

For Locust load test :

```
locust -f load-test/locustfile.py --headless -u n -r 10 --run-time 3m
```

 runtime metrics :

```bash
./scripts/metrics.sh 50
```


View recent results quickly:

saved in results.csv file

## Metrics Collected

| Metric                      | Description                                       |
| --------------------------- | ------------------------------------------------- |
| **Timestamp**               | When the test was executed                        |
| **Users**                   | Number of simulated concurrent users              |
| **Requestpersec (RPS)**     | Throughput — Requests per second handled          |
| **Percentile95_latency_ms** | 95th percentile of response latency (in ms)       |
| **CPU_pods**                | Aggregate CPU usage of pods                       |
| **Memory_pods**             | Aggregate memory usage of pods (MB)               |
| **CPU_nodes**               | CPU usage on Kind nodes                           |
| **Memory_nodes**            | Memory usage on Kind nodes (MB)                   |
| **Ping_intra_ms**           | Latency inside a node (pod-to-pod same node)      |
| **Ping_inter_ms**           | Latency across nodes (pod-to-pod different nodes) |
| **Bandwidth_mbps**          | Network throughput in Mbps                        |




---

Implemented by  
Surya Deepak Boyina(MT25048), Kancharla Tholi Kiran(MT25038)
