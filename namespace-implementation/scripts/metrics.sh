#!/bin/bash
# ============================================================================
# metrics.sh — Collect performance metrics for namespace-based benchmarking
#
# Adapted from the K8s-based scripts/metrics.sh
# Uses Prometheus for CPU/memory, Locust stats for RPS/P95, ping/iperf for network
#
# Usage: sudo ./metrics.sh <num_users> [results_file]
# ============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"

USERS="${1:?Usage: $0 <num_users> [results_file]}"
RESULTS_FILE="${2:-$PROJECT_ROOT/results/namespace_results.csv}"

# -------------------- IP Configuration --------------------
SVC_A_IP="10.0.1.2"
SVC_B_IP="10.0.1.3"
SVC_C_IP="10.0.2.2"

PROM_URL="http://localhost:9090/api/v1/query"

# -------------------- Ensure CSV exists --------------------
if [ ! -f "$RESULTS_FILE" ]; then
    echo "timestamp,users,rps,p95_latency_ms,cpu_pods,memory_pods,cpu_nodes,memory_nodes,ping_intra_ms,ping_inter_ms,bandwidth_mbps" > "$RESULTS_FILE"
fi

echo "📊 Collecting metrics for $USERS users..."

# -------------------- Locust metrics --------------------
STATS_FILE="$PROJECT_ROOT/load-test/locust_stats_stats.csv"

if [ -f "$STATS_FILE" ]; then
    P95=$(awk -F',' 'NR>1 && $2=="Aggregated"{print $17}' "$STATS_FILE" | tail -1)
    RPS=$(awk -F',' 'NR>1 && $2=="Aggregated"{print $10}' "$STATS_FILE" | tail -1)
else
    echo "  ⚠️ Locust stats file not found at: $STATS_FILE"
fi
P95=${P95:-NA}
RPS=${RPS:-NA}

# -------------------- Prometheus metrics --------------------
query_prometheus() {
    local result
    result=$(curl -sG "$PROM_URL" --data-urlencode "query=$1" \
            | jq -r '.data.result[0].value[1]' 2>/dev/null)
    [[ -z "$result" || "$result" == "null" ]] && echo "NA" || echo "$result"
}

# Check if Prometheus is reachable
if curl -s "$PROM_URL" --data-urlencode "query=up" > /dev/null 2>&1; then
    echo "  📊 Fetching Prometheus metrics..."

    # Process CPU (sum of service processes)
    CPU_PODS=$(query_prometheus 'sum(rate(namedprocess_namegroup_cpu_seconds_total{groupname=~".*service.*"}[1m]))')
    [[ "$CPU_PODS" == "NA" ]] || CPU_PODS=$(printf "%.4f" "$CPU_PODS")

    # Process Memory (bytes → MiB)
    MEM_PODS_RAW=$(query_prometheus 'sum(namedprocess_namegroup_memory_bytes{groupname=~".*service.*",memtype="resident"})')
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
else
    echo "  ⚠️ Prometheus not reachable, using NA for CPU/memory metrics"
    CPU_PODS="NA"
    MEM_PODS="NA"
    CPU_NODES="NA"
    MEM_NODES="NA"
fi

# Fallback safety
CPU_PODS=${CPU_PODS:-NA}
MEM_PODS=${MEM_PODS:-NA}
CPU_NODES=${CPU_NODES:-NA}
MEM_NODES=${MEM_NODES:-NA}

# -------------------- Ping (intra-node / inter-node) --------------------
echo "  📊 Measuring ping latency..."

# Intra-node: svc-a → svc-b (both on br-node1)
PING_INTRA=$(ip netns exec ns-svc-a ping -c 5 -q "$SVC_B_IP" 2>/dev/null \
    | tail -1 | awk -F '/' '{print $5}')
PING_INTRA=${PING_INTRA:-NA}

# Inter-node: svc-a → svc-c (across bridges)
PING_INTER=$(ip netns exec ns-svc-a ping -c 5 -q "$SVC_C_IP" 2>/dev/null \
    | tail -1 | awk -F '/' '{print $5}')
PING_INTER=${PING_INTER:-NA}

echo "  Ping intra-node: ${PING_INTRA} ms"
echo "  Ping inter-node: ${PING_INTER} ms"

# -------------------- iperf3 bandwidth --------------------
echo "  📊 Measuring bandwidth with iperf3..."

BANDWIDTH_MBPS="NA"

if command -v iperf3 &>/dev/null; then
    # Start iperf3 server in svc-c namespace (background)
    ip netns exec ns-svc-c iperf3 -s -D -p 5201 2>/dev/null || true
    sleep 1

    # Run client from svc-a namespace
    IPERF_JSON=$(ip netns exec ns-svc-a iperf3 -c "$SVC_C_IP" -J -p 5201 -t 5 2>/dev/null || echo "")

    if [ -n "$IPERF_JSON" ] && command -v jq &>/dev/null; then
        BANDWIDTH_BPS=$(echo "$IPERF_JSON" | jq -r '
            .end.sum_received.bits_per_second //
            .end.sum_sent.bits_per_second //
            empty
        ' 2>/dev/null)

        if [ -n "$BANDWIDTH_BPS" ]; then
            BANDWIDTH_MBPS=$(echo "scale=3; $BANDWIDTH_BPS / 1000000" | bc)
        fi
    fi

    # Kill iperf server
    ip netns exec ns-svc-c pkill iperf3 2>/dev/null || true
else
    echo "  ⚠️ iperf3 not found, skipping bandwidth measurement"
fi

echo "  Bandwidth: ${BANDWIDTH_MBPS} Mbps"

# -------------------- Save results --------------------
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

echo "$TIMESTAMP,$USERS,$RPS,$P95,$CPU_PODS,$MEM_PODS,$CPU_NODES,$MEM_NODES,$PING_INTRA,$PING_INTER,$BANDWIDTH_MBPS" >> "$RESULTS_FILE"

echo ""
echo "  ✅ Metrics saved to $RESULTS_FILE"
echo "  Row: $TIMESTAMP,$USERS,$RPS,$P95,$CPU_PODS,$MEM_PODS,$CPU_NODES,$MEM_NODES,$PING_INTRA,$PING_INTER,$BANDWIDTH_MBPS"
