#!/bin/bash
# ==============================================================================
# reset_cluster.sh — Tear down the bare-metal Kubernetes cluster
# Cleans up kubeadm state, CNI residuals, iptables, and virtual interfaces
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}🔹 $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }

# ==============================================================================
# Preflight
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ This script must be run as root (use sudo)${NC}"
    exit 1
fi

echo ""
echo "============================================================"
echo -e "${YELLOW}⚠️  This will completely tear down the Kubernetes cluster${NC}"
echo "============================================================"
echo ""

# Allow --force flag to skip confirmation
if [[ "${1:-}" != "--force" ]]; then
    read -rp "Are you sure? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ==============================================================================
# Step 1: Kill port-forward processes
# ==============================================================================
log "Step 1: Killing port-forward processes..."
pkill -f "kubectl port-forward" 2>/dev/null || true
success "Port-forwards killed"

# ==============================================================================
# Step 2: kubeadm reset
# ==============================================================================
log "Step 2: Running kubeadm reset..."
if command -v kubeadm &>/dev/null; then
    kubeadm reset --force 2>/dev/null || true
    success "kubeadm reset complete"
else
    warn "kubeadm not found, skipping reset"
fi

# ==============================================================================
# Step 3: Stop kubelet
# ==============================================================================
log "Step 3: Stopping kubelet..."
systemctl stop kubelet 2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true
success "kubelet stopped"

# ==============================================================================
# Step 4: Clean up CNI configuration and state
# ==============================================================================
log "Step 4: Cleaning CNI configuration and state..."
rm -rf /etc/cni/net.d/*
rm -rf /var/lib/cni/
rm -rf /var/run/flannel/
rm -rf /run/flannel/
rm -rf /var/lib/calico/
rm -rf /var/run/calico/
rm -rf /var/lib/cilium/
rm -rf /run/cilium/
success "CNI state cleaned"

# ==============================================================================
# Step 5: Clean up virtual network interfaces
# ==============================================================================
log "Step 5: Removing CNI virtual interfaces..."

# Flannel
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true

# Calico
ip link delete tunl0 2>/dev/null || true
ip link delete vxlan.calico 2>/dev/null || true

# Cilium
for iface in $(ip link show 2>/dev/null | grep -oP 'cilium_\w+' | sort -u); do
    ip link delete "$iface" 2>/dev/null || true
done
for iface in $(ip link show 2>/dev/null | grep -oP 'lxc\w+' | sort -u); do
    ip link delete "$iface" 2>/dev/null || true
done
ip link delete cilium_host 2>/dev/null || true
ip link delete cilium_net 2>/dev/null || true
ip link delete cilium_vxlan 2>/dev/null || true

success "Virtual interfaces removed"

# ==============================================================================
# Step 6: Flush iptables
# ==============================================================================
log "Step 6: Flushing iptables rules..."
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true

# Also flush ip6tables
ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
ip6tables -t nat -X 2>/dev/null || true

# Flush nftables if present
nft flush ruleset 2>/dev/null || true

success "iptables/nftables flushed"

# ==============================================================================
# Step 7: Clean up eBPF maps (Cilium)
# ==============================================================================
log "Step 7: Cleaning eBPF maps..."
if mount | grep -q "bpf"; then
    find /sys/fs/bpf -type f -delete 2>/dev/null || true
    find /sys/fs/bpf -mindepth 1 -type d -delete 2>/dev/null || true
fi
success "eBPF maps cleaned"

# ==============================================================================
# Step 8: Clean up Kubernetes directories
# ==============================================================================
log "Step 8: Cleaning Kubernetes directories..."
rm -rf /etc/kubernetes/
rm -rf /var/lib/kubelet/
rm -rf /var/lib/etcd/
success "Kubernetes directories cleaned"

# ==============================================================================
# Step 9: Reset kubeconfig
# ==============================================================================
log "Step 9: Resetting kubeconfig..."
rm -f "$HOME/.kube/config"
if [[ -n "${SUDO_USER:-}" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    rm -f "$USER_HOME/.kube/config"
fi
success "kubeconfig removed"

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "============================================================"
echo -e "${GREEN}🎉 Bare-metal Kubernetes cluster fully torn down${NC}"
echo "============================================================"
echo ""
echo "To set up a fresh cluster:"
echo "  sudo bash $SCRIPT_DIR/setup_cluster.sh"
echo ""
