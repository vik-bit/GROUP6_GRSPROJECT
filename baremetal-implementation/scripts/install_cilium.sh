#!/bin/bash
# ==============================================================================
# install_cilium.sh — Install Cilium CNI on the bare-metal cluster
# ==============================================================================
set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()     { echo -e "${BLUE}🔹 $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }

# ==============================================================================
# Preflight
# ==============================================================================
if ! kubectl cluster-info &>/dev/null; then
    echo "❌ Cannot connect to cluster. Is the cluster running?"
    exit 1
fi

# ==============================================================================
# Install Cilium CLI if not present
# ==============================================================================
if ! command -v cilium &>/dev/null; then
    log "Installing Cilium CLI..."

    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH=amd64
    [[ "$(uname -m)" == "aarch64" ]] && CLI_ARCH=arm64

    curl -L --fail --remote-name-all \
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}"

    sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
    sudo tar xzvfC "cilium-linux-${CLI_ARCH}.tar.gz" /usr/local/bin
    rm -f "cilium-linux-${CLI_ARCH}.tar.gz" "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"

    success "Cilium CLI installed"
else
    success "Cilium CLI already installed: $(cilium version --client 2>/dev/null | head -1)"
fi

# ==============================================================================
# Install Cilium
# ==============================================================================
log "Installing Cilium CNI..."

cilium install \
    --version 1.16.5 \
    --set kubeProxyReplacement=true \
    --set ipam.operator.clusterPoolIPv4PodCIDRList=10.244.0.0/16

log "Waiting for Cilium to be ready..."
cilium status --wait --wait-duration 300s

success "Cilium installed"

# Wait for the node to become Ready
log "Waiting for node to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

success "Cilium installed and node is Ready"

echo ""
kubectl get nodes -o wide
echo ""
cilium status
echo ""
