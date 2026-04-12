#!/bin/bash
# ============================================================================
# run_experiment.sh — Full experiment orchestrator
#
# Runs the complete benchmarking cycle:
#   1. Setup topology
#   2. Start services (inline, not via run_services.sh)
#   3. Setup monitoring (optional)
#   4. Run Locust load tests at multiple user levels
#   5. Collect metrics after each level
#   6. Cleanup
#
# Usage: sudo ./run_experiment.sh [--mode bridge|vxlan|iptables] [--skip-monitoring]
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"
SRC_DIR="$PROJECT_ROOT/src"
BINARY="$SRC_DIR/service"
RESULTS_DIR="$PROJECT_ROOT/results"
LOCUST_DIR="$PROJECT_ROOT/load-test"

# -------------------- Parse arguments --------------------
MODE="bridge"
SKIP_MONITORING=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --skip-monitoring)
            SKIP_MONITORING=true
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--mode bridge|vxlan|iptables] [--skip-monitoring]"
            exit 1
            ;;
    esac
done

# -------------------- Configuration --------------------
SVC_A_IP="10.0.1.2"
SVC_B_IP="10.0.1.3"
SVC_C_IP="10.0.2.2"
USER_LEVELS=(50 100 200 300 400)
SPAWN_RATE=10
RUN_TIME="1m"
RESULTS_FILE="$RESULTS_DIR/namespace_${MODE}_results.csv"

echo "============================================"
echo "🧪 Namespace Benchmark Experiment"
echo "   Mode: $MODE"
echo "   Users: ${USER_LEVELS[*]}"
echo "   Results: $RESULTS_FILE"
echo "============================================"

# -------------------- Step 1: Cleanup previous --------------------
echo ""
echo "🧹 Step 1: Cleaning up previous runs..."
"$SCRIPT_DIR/cleanup.sh" || true

# -------------------- Step 2: Setup topology --------------------
echo ""
echo "🌐 Step 2: Setting up topology (mode: $MODE)..."
"$SCRIPT_DIR/setup_topology.sh" --mode "$MODE"

# -------------------- Step 3: Compile service --------------------
echo ""
echo "🔨 Step 3: Compiling microservice..."
if [ ! -f "$BINARY" ] || [ "$SRC_DIR/service.c" -nt "$BINARY" ]; then
    make -C "$SRC_DIR" clean all
else
    echo "  ✅ Binary up to date"
fi

# -------------------- Step 4: Kill old + Start services directly --------------------
echo ""
echo "🚀 Step 4: Starting services..."

# Kill any leftover service processes
for ns in ns-svc-a ns-svc-b ns-svc-c; do
    pids=$(ip netns pids "$ns" 2>/dev/null || true)
    for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
done
sleep 1

# Start service-c (terminal)
ip netns exec ns-svc-c env SERVICE_NAME="service-c" NEXT_SERVICE="" \
    "$BINARY" > /tmp/ns-svc-c.log 2>&1 &
sleep 1

# Start service-b (forwards to C)
ip netns exec ns-svc-b env SERVICE_NAME="service-b" NEXT_SERVICE="http://${SVC_C_IP}:8080" \
    "$BINARY" > /tmp/ns-svc-b.log 2>&1 &
sleep 1

# Start service-a (forwards to B)
ip netns exec ns-svc-a env SERVICE_NAME="service-a" NEXT_SERVICE="http://${SVC_B_IP}:8080" \
    "$BINARY" > /tmp/ns-svc-a.log 2>&1 &
sleep 1

echo "  ✅ All 3 services started"

# Verify with retry
echo "  Verifying service chain..."
CHAIN_OK=false
for attempt in $(seq 1 10); do
    RESP=$(curl -s --max-time 10 "http://${SVC_A_IP}:8080/" 2>/dev/null || echo "")
    if [[ "$RESP" == *"service-c"* ]]; then
        CHAIN_OK=true
        echo "  ✅ Service chain verified: $RESP"
        break
    fi
    echo "  ⏳ Attempt $attempt/10 — waiting for services..."
    sleep 2
done

if [ "$CHAIN_OK" = false ]; then
    echo "❌ Service chain not responding after 10 attempts!"
    echo "   Last response: '$RESP'"
    echo "   Check logs: cat /tmp/ns-svc-{a,b,c}.log"
    exit 1
fi

# -------------------- Step 5: Setup monitoring --------------------
if [ "$SKIP_MONITORING" = false ]; then
    echo ""
    echo "📊 Step 5: Setting up monitoring..."
    "$SCRIPT_DIR/setup_monitoring.sh"
else
    echo ""
    echo "📊 Step 5: Skipping monitoring (--skip-monitoring)"
fi

# -------------------- Step 6: Find Locust --------------------
echo ""
echo "🦗 Step 6: Checking Locust..."

LOCUST_BIN=""

# Check if locust is already in PATH
if command -v locust &>/dev/null; then
    LOCUST_BIN="locust"
fi

# Check project virtualenv
if [ -z "$LOCUST_BIN" ] && [ -f "$PROJECT_ROOT/../.venv/bin/locust" ]; then
    LOCUST_BIN="$PROJECT_ROOT/../.venv/bin/locust"
    echo "  Found Locust in project .venv"
fi

# Check calling user's home (sudo preserves SUDO_USER)
if [ -z "$LOCUST_BIN" ] && [ -n "$SUDO_USER" ]; then
    USER_HOME=$(eval echo "~$SUDO_USER")
    for candidate in \
        "$USER_HOME/.local/bin/locust" \
        "$USER_HOME/.venv/bin/locust" \
        "/home/$SUDO_USER/.local/bin/locust"; do
        if [ -f "$candidate" ]; then
            LOCUST_BIN="$candidate"
            echo "  Found Locust at $candidate"
            break
        fi
    done
fi

# Check common system paths
if [ -z "$LOCUST_BIN" ]; then
    for candidate in /usr/local/bin/locust /usr/bin/locust; do
        if [ -f "$candidate" ]; then
            LOCUST_BIN="$candidate"
            break
        fi
    done
fi

# Last resort: try to install
if [ -z "$LOCUST_BIN" ]; then
    echo "  Locust not found, attempting install..."
    pip install locust 2>/dev/null || pip3 install locust 2>/dev/null || true
    if command -v locust &>/dev/null; then
        LOCUST_BIN="locust"
    fi
fi

if [ -z "$LOCUST_BIN" ]; then
    echo "❌ Locust not found!"
    echo "   Install it in your virtualenv: pip install locust"
    echo "   Or system-wide: sudo pip install locust"
    exit 1
fi
echo "  ✅ Locust: $LOCUST_BIN"

# -------------------- Step 7: CSV header --------------------
mkdir -p "$RESULTS_DIR"
echo "timestamp,users,rps,p95_latency_ms,cpu_pods,memory_pods,cpu_nodes,memory_nodes,ping_intra_ms,ping_inter_ms,bandwidth_mbps" > "$RESULTS_FILE"

# -------------------- Step 8: Run experiments --------------------
echo ""
echo "🔬 Step 7: Running load tests..."

cd "$LOCUST_DIR"

for USERS in "${USER_LEVELS[@]}"; do
    echo ""
    echo "========================================"
    echo "🚀 Running test with $USERS users (mode: $MODE)"
    echo "========================================"

    # Run Locust
    "$LOCUST_BIN" -f locustfile.py \
        --host="http://${SVC_A_IP}:8080" \
        --headless \
        -u "$USERS" \
        -r "$SPAWN_RATE" \
        --run-time "$RUN_TIME" \
        --csv=locust_stats

    # Collect metrics
    echo "📊 Collecting metrics for $USERS users..."
    "$SCRIPT_DIR/metrics.sh" "$USERS" "$RESULTS_FILE"

    echo "✅ Completed test for $USERS users"
done

cd "$SCRIPT_DIR"

# -------------------- Step 9: Summary --------------------
echo ""
echo "============================================"
echo "✅ Experiment complete!"
echo ""
echo "  Results: $RESULTS_FILE"
echo "  Mode: $MODE"
echo ""
echo "  CSV contents:"
cat "$RESULTS_FILE"
echo ""
echo "  To cleanup: sudo ./cleanup.sh"
echo "============================================"
