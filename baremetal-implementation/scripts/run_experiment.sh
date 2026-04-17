#!/bin/bash
# ==============================================================================
# run_experiment.sh — Full bare-metal CNI benchmarking pipeline
# Usage: sudo bash run_experiment.sh <cni_name>
#        sudo bash run_experiment.sh flannel
#        sudo bash run_experiment.sh calico
#        sudo bash run_experiment.sh cilium
#        sudo bash run_experiment.sh all   (runs all three sequentially)
# ==============================================================================
set -euo pipefail
trap 'echo "❌ Error at line $LINENO"; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"
REPO_ROOT="$(realpath "$PROJECT_ROOT/..")"

CNI_NAME="${1:?Usage: run_experiment.sh <flannel|calico|cilium|all>}"

# Locust configuration
USER_LEVELS=(50 100 200 300 400)
SPAWN_RATE=10
RUN_TIME="1m"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()     { echo -e "${BLUE}🔹 $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail()    { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ==============================================================================
# Validate CNI name
# ==============================================================================
VALID_CNIS=("flannel" "calico" "cilium")

if [[ "$CNI_NAME" != "all" ]]; then
    found=false
    for cni in "${VALID_CNIS[@]}"; do
        [[ "$cni" == "$CNI_NAME" ]] && found=true
    done
    [[ "$found" == "true" ]] || fail "Invalid CNI: $CNI_NAME. Use: flannel, calico, cilium, or all"
fi

# ==============================================================================
# Check Locust is installed
# ==============================================================================
export PATH="$PATH:$HOME/.local/bin"

if ! command -v locust &>/dev/null; then
    log "Installing Locust..."
    if command -v pipx &>/dev/null; then
        pipx install locust
    elif command -v pip &>/dev/null; then
        pip install --user locust
    else
        fail "Cannot install Locust. Install pipx or pip first."
    fi
fi

if ! command -v locust &>/dev/null; then
    fail "Locust not found in PATH after installation."
fi

# ==============================================================================
# Run experiment for a single CNI
# ==============================================================================
run_cni_experiment() {
    local cni="$1"
    local results_file="$PROJECT_ROOT/results/${cni}_results.csv"

    echo ""
    echo "============================================================"
    echo -e "${GREEN}🚀 Starting experiment: $cni${NC}"
    echo "============================================================"
    echo ""

    # ------------------------------------------------------------------
    # Step 1: Reset and setup cluster
    # ------------------------------------------------------------------
    log "Resetting cluster..."
    bash "$SCRIPT_DIR/reset_cluster.sh" --force

    log "Setting up fresh cluster..."
    bash "$SCRIPT_DIR/setup_cluster.sh"

    # ------------------------------------------------------------------
    # Step 2: Install CNI
    # ------------------------------------------------------------------
    log "Installing $cni CNI..."
    bash "$SCRIPT_DIR/install_${cni}.sh"

    # ------------------------------------------------------------------
    # Step 3: Deploy workloads
    # ------------------------------------------------------------------
    log "Deploying workloads..."
    bash "$SCRIPT_DIR/deploy_workload.sh"

    # ------------------------------------------------------------------
    # Step 4: Optional — install lightweight monitoring
    # ------------------------------------------------------------------
    log "Installing metrics-server..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml 2>/dev/null || true
    # Patch for single-node (no TLS verification needed)
    kubectl patch deployment metrics-server -n kube-system \
        --type='json' \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' 2>/dev/null || true
    sleep 10

    # ------------------------------------------------------------------
    # Step 5: Run load tests
    # ------------------------------------------------------------------
    log "Starting load tests for $cni..."

    # Create results header
    echo "timestamp,users,rps,p95_latency_ms,cpu_pods,memory_pods_mib,cpu_nodes_pct,memory_nodes_mib,ping_intra_ms,bandwidth_mbps" > "$results_file"

    for USERS in "${USER_LEVELS[@]}"; do
        echo ""
        echo "========================================"
        echo -e "${BLUE}🔥 $cni — $USERS users${NC}"
        echo "========================================"

        # Run Locust
        cd "$PROJECT_ROOT/results"
        locust -f "$REPO_ROOT/load-test/locustfile.py" \
            --host=http://localhost:8080 \
            --headless \
            -u "$USERS" \
            -r "$SPAWN_RATE" \
            --run-time "$RUN_TIME" \
            --csv=locust_stats

        # Collect metrics
        bash "$SCRIPT_DIR/metrics.sh" "$USERS" "$results_file"

        success "Completed $cni with $USERS users"
    done

    success "All tests complete for $cni — results in $results_file"
}

# ==============================================================================
# Main: run for specified CNI(s)
# ==============================================================================
mkdir -p "$PROJECT_ROOT/results"

if [[ "$CNI_NAME" == "all" ]]; then
    for cni in "${VALID_CNIS[@]}"; do
        run_cni_experiment "$cni"
    done
else
    run_cni_experiment "$CNI_NAME"
fi

echo ""
echo "============================================================"
echo -e "${GREEN}🎉 All experiments complete!${NC}"
echo "============================================================"
echo ""
echo "Results:"
ls -la "$PROJECT_ROOT/results/"*.csv 2>/dev/null
echo ""
