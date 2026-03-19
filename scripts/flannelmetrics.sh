#!/bin/bash
set -e

# ------------------- Resolve project root properly -------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"

RESULTS_FILE="$PROJECT_ROOT/results.csv"

echo "📊 Collecting metrics..."

# ------------------- Config -------------------
USERS=50

# ------------------- Ensure CSV exists -------------------
if [ ! -f "$RESULTS_FILE" ]; then
  echo "timestamp,users,rps,p95_latency_ms,cpu_pods,memory_pods,cpu_nodes,memory_nodes,ping_intra_ms,ping_inter_ms,bandwidth_mbps" > "$RESULTS_FILE"
fi

# ------------------- Extract Locust metrics -------------------
STATS_FILE="$PROJECT_ROOT/load-test/locust_stats_stats.csv"

if [ ! -f "$STATS_FILE" ]; then
  echo "❌ Locust stats file not found at: $STATS_FILE"
  exit 1
fi

P95=$(awk -F',' 'NR>1 && $1=="Aggregated"{print $8}' "$STATS_FILE")
RPS=$(awk -F',' 'NR>1 && $1=="Aggregated"{print $13}' "$STATS_FILE")

# ------------------- Kubernetes metrics -------------------
CPU_PODS=0
MEM_PODS=0

while read -r cpu mem; do
  CPU_PODS=$(echo "$CPU_PODS + ${cpu%m}" | bc)
  MEM_PODS=$(echo "$MEM_PODS + ${mem%Mi}" | bc)
done < <(kubectl top pods --no-headers | awk '{print $2, $3}')

CPU_NODES=0
MEM_NODES=0

while read -r cpu mem; do
  CPU_NODES=$(echo "$CPU_NODES + ${cpu%m}" | bc)
  MEM_NODES=$(echo "$MEM_NODES + ${mem%Mi}" | bc)
done < <(kubectl top nodes --no-headers | awk '{print $2, $4}')

# ------------------- Network (ping intra/inter) -------------------
# Replace these with your actual pod names
INTRA_POD=$(kubectl get pods -l app=service-b -o jsonpath='{.items[0].metadata.name}')
INTER_POD=$(kubectl get pods -l app=service-c -o jsonpath='{.items[0].metadata.name}')

INTRA_IP=$(kubectl get pod "$INTRA_POD" -o jsonpath='{.status.podIP}')
INTER_IP=$(kubectl get pod "$INTER_POD" -o jsonpath='{.status.podIP}')

PING_INTRA=$(kubectl exec "$INTRA_POD" -- ping -c 3 "$INTRA_IP" | tail -1 | awk -F '/' '{print $5}')
PING_INTER=$(kubectl exec "$INTRA_POD" -- ping -c 3 "$INTER_IP" | tail -1 | awk -F '/' '{print $5}')

# ------------------- iperf3 bandwidth -------------------
IPERF_IP=$(kubectl get svc iperf-service -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

if [ -n "$IPERF_IP" ]; then
  IPERF_OUT=$(iperf3 -c "$IPERF_IP" -J 2>/dev/null || true)

  if command -v jq &> /dev/null && [ -n "$IPERF_OUT" ]; then
    BANDWIDTH_BPS=$(echo "$IPERF_OUT" | jq '.end.sum_received.bits_per_second')
    BANDWIDTH_MBPS=$(echo "$BANDWIDTH_BPS / 1000000" | bc)
  else
    BANDWIDTH_MBPS="NA"
  fi
else
  BANDWIDTH_MBPS="NA"
fi

# ------------------- Save results -------------------
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

echo "$TIMESTAMP,$USERS,$RPS,$P95,$CPU_PODS,$MEM_PODS,$CPU_NODES,$MEM_NODES,$PING_INTRA,$PING_INTER,$BANDWIDTH_MBPS" >> "$RESULTS_FILE"

echo "✅ Metrics collected and saved to $RESULTS_FILE"