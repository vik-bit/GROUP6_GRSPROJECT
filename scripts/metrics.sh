#!/bin/bash
set -e

# ------------------- Resolve project root properly -------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"

RESULTS_FILE="$PROJECT_ROOT/results.csv"
# ------------------- Wait for Prometheus pod -------------------
PROM_POD=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
echo "⏳ Waiting for Prometheus pod ($PROM_POD) to be Ready..."
kubectl wait --for=condition=Ready pod/$PROM_POD -n monitoring --timeout=180s
echo "✅ Prometheus pod is Ready"

# ------------------- Port-forward Prometheus -------------------
kubectl port-forward pod/$PROM_POD 9090:9090 -n monitoring > /dev/null 2>&1 &
echo "📊 Prometheus port-forwarded to localhost:9090"

PROM_URL="http://localhost:9090/api/v1/query"

query_prometheus() {
  local result
  result=$(curl -sG "$PROM_URL" --data-urlencode "query=$1" \
            | jq -r '.data.result[0].value[1]' 2>/dev/null)
  [[ -z "$result" || "$result" == "null" ]] && echo "NA" || echo "$result"
}


echo "📊 Collecting metrics..."

# ------------------- Config -------------------
USERS=$1
echo "Collecting metrics for $USERS users..."

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

# ✅ FIXED: correct columns + correct field match + last row only
P95=$(awk -F',' 'NR>1 && $2=="Aggregated"{print $17}' "$STATS_FILE" | tail -1)
RPS=$(awk -F',' 'NR>1 && $2=="Aggregated"{print $10}' "$STATS_FILE" | tail -1)

# fallback if empty
P95=${P95:-NA}
RPS=${RPS:-NA}

# ------------------- Prometheus metrics -------------------
echo "📊 Fetching Prometheus metrics..."

query_prometheus() {
  local result
  result=$(curl -sG "$PROM_URL" --data-urlencode "query=$1" \
            | jq -r '.data.result[0].value[1]' 2>/dev/null)
  # If empty or null, return NA
  if [[ -z "$result" || "$result" == "null" ]]; then
    echo "NA"
  else
    echo "$result"
  fi
}

# Pod CPU (cores)
CPU_PODS=$(query_prometheus 'sum(rate(container_cpu_usage_seconds_total{container!=""}[1m]))')
[[ "$CPU_PODS" == "NA" ]] || CPU_PODS=$(printf "%.2f" "$CPU_PODS")

# Pod Memory (bytes → MiB)
MEM_PODS_RAW=$(query_prometheus 'sum(container_memory_usage_bytes{container!=""})')
if [[ "$MEM_PODS_RAW" != "NA" ]]; then
    MEM_PODS=$(echo "scale=2; $MEM_PODS_RAW / 1024 / 1024" | bc)
else
    MEM_PODS="NA"
fi

# Node CPU (%)
CPU_NODES=$(query_prometheus '100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)')
[[ "$CPU_NODES" == "NA" ]] || CPU_NODES=$(printf "%.2f" "$CPU_NODES")

# Node Memory (bytes → MiB)
MEM_NODES_RAW=$(query_prometheus 'sum(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)')
if [[ "$MEM_NODES_RAW" != "NA" ]]; then
    MEM_NODES=$(echo "scale=2; $MEM_NODES_RAW / 1024 / 1024" | bc)
else
    MEM_NODES="NA"
fi

# fallback safety
CPU_PODS=${CPU_PODS:-NA}
CPU_NODES=${CPU_NODES:-NA}

# ------------------- Network (ping intra/inter) -------------------
INTRA_POD=$(kubectl get pods -l app=service-b -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
INTER_POD=$(kubectl get pods -l app=service-c -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$INTRA_POD" ] && [ -n "$INTER_POD" ]; then
  INTRA_IP=$(kubectl get pod "$INTRA_POD" -o jsonpath='{.status.podIP}')
  INTER_IP=$(kubectl get pod "$INTER_POD" -o jsonpath='{.status.podIP}')

  PING_INTRA=$(kubectl exec "$INTRA_POD" -- ping -c 3 "$INTRA_IP" | tail -1 | awk -F '/' '{print $5}')
  PING_INTER=$(kubectl exec "$INTRA_POD" -- ping -c 3 "$INTER_IP" | tail -1 | awk -F '/' '{print $5}')
else
  PING_INTRA="NA"
  PING_INTER="NA"
fi


# ------------------- iperf3 bandwidth (auto setup) -------------------

echo "🔧 Ensuring iperf server is running..."

# Check if service exists
if ! kubectl get svc iperf-service >/dev/null 2>&1; then
  echo "⚠️ iperf-service not found. Creating iperf server..."

  # Create iperf server pod if not exists
  if ! kubectl get pod iperf-server >/dev/null 2>&1; then
    kubectl run iperf-server \
      --image=networkstatic/iperf3 \
      --labels="app=iperf" \
      --restart=Never \
      -- -s
  fi

  # Expose service
  kubectl expose pod iperf-server \
    --name=iperf-service \
    --port=5201 \
    --target-port=5201

  echo "⏳ Waiting for iperf server to be ready..."
  sleep 5
else
  echo "✅ iperf-service already exists"
fi



# Run iperf inside cluster and capture ONLY JSON output
echo "🚀 Running iperf test..."

IPERF_RAW=$(kubectl run iperf-client --rm -i --restart=Never \
  --image=networkstatic/iperf3 \
  -- iperf3 -c iperf-service -J 2>&1)

BANDWIDTH_MBPS="NA"

# Extract only JSON block
IPERF_JSON=$(echo "$IPERF_RAW" | sed -n '/^{/,$p' | sed '/^}/q')

if command -v jq >/dev/null 2>&1 && [ -n "$IPERF_JSON" ]; then
  BANDWIDTH_BPS=$(echo "$IPERF_JSON" | jq -r '
    .end.sum_received.bits_per_second //
    .end.sum_sent.bits_per_second //
    empty
  ' 2>/dev/null)

  if [ -n "$BANDWIDTH_BPS" ]; then
    BANDWIDTH_MBPS=$(echo "scale=3; $BANDWIDTH_BPS / 1000000" | bc)
  fi
fi

# ------------------- Save results -------------------
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

echo "$TIMESTAMP,$USERS,$RPS,$P95,$CPU_PODS,$MEM_PODS,$CPU_NODES,$MEM_NODES,$PING_INTRA,$PING_INTER,$BANDWIDTH_MBPS" >> "$RESULTS_FILE"
