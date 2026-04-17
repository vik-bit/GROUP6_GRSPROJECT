#!/bin/bash
# ==============================================================================
# install_flannel.sh — Install Flannel CNI on the bare-metal cluster
# ==============================================================================
set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

log()     { echo -e "${BLUE}🔹 $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }

# ==============================================================================
# Preflight
# ==============================================================================
if ! kubectl cluster-info &>/dev/null; then
    echo "❌ Cannot connect to cluster. Is the cluster running?"
    exit 1
fi

# Check if another CNI is already installed
if kubectl get pods -n kube-system -l app=flannel 2>/dev/null | grep -q Running; then
    success "Flannel is already running"
    exit 0
fi

# ==============================================================================
# Install Flannel
# ==============================================================================
log "Installing Flannel CNI..."

kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

log "Waiting for Flannel pods to be ready..."
kubectl wait --for=condition=Ready pods \
    -l app=flannel \
    -n kube-flannel \
    --timeout=120s 2>/dev/null || \
kubectl wait --for=condition=Ready pods \
    -l app=flannel \
    -n kube-system \
    --timeout=120s 2>/dev/null || true

# Wait for the node to become Ready
log "Waiting for node to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

success "Flannel installed and node is Ready"

echo ""
kubectl get nodes -o wide
echo ""
kubectl get pods -n kube-flannel 2>/dev/null || kubectl get pods -n kube-system -l app=flannel 2>/dev/null
echo ""
