#!/bin/bash
# ==============================================================================
# metrics.sh — Collect performance metrics for bare-metal experiments
# Adapted from the Kind implementation's metrics.sh
# Usage: sudo bash metrics.sh <user_count> [results_file]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"
REPO_ROOT="$(realpath "$PROJECT_ROOT/..")"

USERS="${1:?Usage: metrics.sh <user_count> [results_file]}"
RESULTS_FILE="${2:-$PROJECT_ROOT/results/results.csv}"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()     { echo -e "${BLUE}📊 $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }

# ==============================================================================
# Ensure results CSV exists with header
# ==============================================================================
if [[ ! -f "$RESULTS_FILE" ]]; then
    mkdir -p "$(dirname "$RESULTS_FILE")"
    echo "timestamp,users,rps,p95_latency_ms,cpu_pods,memory_pods_mib,cpu_nodes_pct,memory_nodes_mib,ping_intra_ms,bandwidth_mbps" > "$RESULTS_FILE"
fi

# ==============================================================================
# Extract Locust metrics
# ==============================================================================
log "Extracting Locust metrics..."

STATS_FILE="$PROJECT_ROOT/results/locust_stats_stats.csv"

if [[ -f "$STATS_FILE" ]]; then
    P95=$(awk -F',' 'NR>1 && $2=="Aggregated"{print $17}' "$STATS_FILE" | tail -1)
    RPS=$(awk -F',' 'NR>1 && $2=="Aggregated"{print $10}' "$STATS_FILE" | tail -1)
else
    warn "Locust stats file not found at $STATS_FILE"
    P95="NA"
    RPS="NA"
fi

P95=${P95:-NA}
RPS=${RPS:-NA}

log "RPS=$RPS, P95=${P95}ms"

# ==============================================================================
# Prometheus metrics (if available)
# ==============================================================================
PROM_URL="http://localhost:9090/api/v1/query"

query_prometheus() {
    local result
    result=$(curl -sG "$PROM_URL" --data-urlencode "query=$1" 2>/dev/null \
        | jq -r '.data.result[0].value[1]' 2>/dev/null) || result=""
    [[ -z "$result" || "$result" == "null" ]] && echo "NA" || echo "$result"
}

# Check if Prometheus is available
if curl -s "$PROM_URL" --data-urlencode "query=up" &>/dev/null; then
    log "Prometheus is available, querying metrics..."

    # Pod CPU (cores)
    CPU_PODS=$(query_prometheus 'sum(rate(container_cpu_usage_seconds_total{container!=""}[1m]))')
    [[ "$CPU_PODS" != "NA" ]] && CPU_PODS=$(printf "%.4f" "$CPU_PODS")

    # Pod Memory (bytes → MiB)
    MEM_PODS_RAW=$(query_prometheus 'sum(container_memory_usage_bytes{container!=""})')
    if [[ "$MEM_PODS_RAW" != "NA" ]]; then
        MEM_PODS=$(echo "scale=2; $MEM_PODS_RAW / 1024 / 1024" | bc)
    else
        MEM_PODS="NA"
    fi

    # Node CPU (%)
    CPU_NODES=$(query_prometheus '100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100)')
    [[ "$CPU_NODES" != "NA" ]] && CPU_NODES=$(printf "%.2f" "$CPU_NODES")

    # Node Memory (bytes → MiB)
    MEM_NODES_RAW=$(query_prometheus 'sum(node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)')
    if [[ "$MEM_NODES_RAW" != "NA" ]]; then
        MEM_NODES=$(echo "scale=2; $MEM_NODES_RAW / 1024 / 1024" | bc)
    else
        MEM_NODES="NA"
    fi

# Fallback: use kubectl top if metrics-server is available
elif kubectl top pods &>/dev/null 2>&1; then
    log "Using kubectl top for metrics..."

    CPU_PODS=$(kubectl top pods --no-headers 2>/dev/null \
        | awk '{sum += $2} END {printf "%.4f", sum/1000}')
    MEM_PODS=$(kubectl top pods --no-headers 2>/dev/null \
        | awk '{sum += $3} END {printf "%.2f", sum}')
    CPU_NODES=$(kubectl top nodes --no-headers 2>/dev/null \
        | awk '{print $3}' | tr -d '%')
    MEM_NODES=$(kubectl top nodes --no-headers 2>/dev/null \
        | awk '{print $5}' | tr -d '%')

else
    warn "Neither Prometheus nor metrics-server available"
    CPU_PODS="NA"
    MEM_PODS="NA"
    CPU_NODES="NA"
    MEM_NODES="NA"
fi

CPU_PODS=${CPU_PODS:-NA}
MEM_PODS=${MEM_PODS:-NA}
CPU_NODES=${CPU_NODES:-NA}
MEM_NODES=${MEM_NODES:-NA}

log "CPU_pods=$CPU_PODS, Mem_pods=${MEM_PODS}MiB, CPU_nodes=${CPU_NODES}%, Mem_nodes=${MEM_NODES}MiB"

# ==============================================================================
# Network metrics: pod-to-pod ping (intra-node only on single-node)
# ==============================================================================
log "Measuring pod-to-pod latency..."

SVC_B_POD=$(kubectl get pods -l app=service-b -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
SVC_C_POD=$(kubectl get pods -l app=service-c -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$SVC_B_POD" && -n "$SVC_C_POD" ]]; then
    SVC_C_IP=$(kubectl get pod "$SVC_C_POD" -o jsonpath='{.status.podIP}')

    PING_INTRA=$(kubectl exec "$SVC_B_POD" -- ping -c 5 "$SVC_C_IP" 2>/dev/null \
        | tail -1 | awk -F '/' '{print $5}') || PING_INTRA="NA"
else
    PING_INTRA="NA"
fi

log "Ping intra-node=$PING_INTRA ms"

# ==============================================================================
# Network metrics: iperf3 bandwidth
# ==============================================================================
log "Measuring bandwidth with iperf3..."

# Ensure iperf server pod exists
if ! kubectl get pod iperf-server &>/dev/null; then
    kubectl run iperf-server --image=networkstatic/iperf3 --labels="app=iperf" --restart=Never -- -s
    kubectl wait --for=condition=Ready pod/iperf-server --timeout=60s
fi

if ! kubectl get svc iperf-service &>/dev/null; then
    kubectl expose pod iperf-server --name=iperf-service --port=5201 --target-port=5201
    sleep 3
fi

BANDWIDTH_MBPS="NA"
IPERF_RAW=$(kubectl run iperf-client --rm -i --restart=Never \
    --image=networkstatic/iperf3 \
    -- iperf3 -c iperf-service -J 2>&1) || true

IPERF_JSON=$(echo "$IPERF_RAW" | sed -n '/^{/,$p' | sed '/^}/q')

if command -v jq &>/dev/null && [[ -n "$IPERF_JSON" ]]; then
    BANDWIDTH_BPS=$(echo "$IPERF_JSON" | jq -r '
        .end.sum_received.bits_per_second //
        .end.sum_sent.bits_per_second //
        empty
    ' 2>/dev/null) || BANDWIDTH_BPS=""

    if [[ -n "$BANDWIDTH_BPS" ]]; then
        BANDWIDTH_MBPS=$(echo "scale=3; $BANDWIDTH_BPS / 1000000" | bc)
    fi
fi

log "Bandwidth=$BANDWIDTH_MBPS Mbps"

# ==============================================================================
# Save results
# ==============================================================================
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

echo "$TIMESTAMP,$USERS,$RPS,$P95,$CPU_PODS,$MEM_PODS,$CPU_NODES,$MEM_NODES,$PING_INTRA,$BANDWIDTH_MBPS" >> "$RESULTS_FILE"

success "Metrics saved to $RESULTS_FILE"
