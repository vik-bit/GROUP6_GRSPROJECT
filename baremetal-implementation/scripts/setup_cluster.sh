#!/bin/bash
# ==============================================================================
# setup_cluster.sh — Initialize a single-node bare-metal Kubernetes cluster
# Target OS: CachyOS (Arch-based)
# This script uses kubeadm directly on the host (no VMs, no Kind/Docker cluster)
# ==============================================================================
set -euo pipefail
trap 'echo "❌ Error at line $LINENO"; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"
CONFIGS_DIR="$PROJECT_ROOT/configs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}🔹 $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail()    { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ==============================================================================
# Preflight Checks
# ==============================================================================
log "Running preflight checks..."

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (use sudo)"
fi

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    log "Detected OS: $PRETTY_NAME"
else
    warn "Cannot detect OS, proceeding anyway..."
fi

# Check architecture
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
    fail "Only x86_64 is supported. Detected: $ARCH"
fi

log "Kernel: $(uname -r)"
log "Architecture: $ARCH"

# ==============================================================================
# Step 1: Disable swap (required by kubeadm)
# ==============================================================================
log "Step 1: Disabling swap..."

# Disable zram swap (CachyOS/Arch default)
# zram is managed by systemd services, swapoff alone won't persist
for svc in systemd-zram-setup@zram0.service zram-setup@zram0.service; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        log "Stopped zram service: $svc"
    fi
done

# Disable the zram generator so it doesn't recreate on reboot
if [[ -f /etc/systemd/zram-generator.conf ]]; then
    mv /etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf.bak
    log "Backed up and removed zram-generator.conf"
fi
# Create empty override to prevent zram generation
mkdir -p /etc/systemd/zram-generator.conf.d
echo "# Disabled for Kubernetes" > /etc/systemd/zram-generator.conf.d/disable.conf
cat > /etc/systemd/zram-generator.conf <<'EOF'
# zram disabled for Kubernetes — original backed up as .bak
EOF

# Now force-disable ALL swap
swapoff -a 2>/dev/null || true

# Verify no swap is active
if swapon --show | grep -q .; then
    # Last resort: individually swapoff each device
    swapon --show=NAME --noheadings | while read -r dev; do
        swapoff "$dev" 2>/dev/null || true
    done
fi

if swapon --show | grep -q .; then
    fail "Could not disable swap. Please manually run: swapoff -a"
else
    success "All swap disabled (including zram)"
fi

# Comment out swap entries in fstab to persist across reboots
if grep -q '^\s*[^#].*\sswap\s' /etc/fstab 2>/dev/null; then
    sed -i '/\sswap\s/s/^/#/' /etc/fstab
    success "Swap entries commented out in /etc/fstab"
fi

# ==============================================================================
# Step 2: Load kernel modules
# ==============================================================================
log "Step 2: Loading kernel modules..."

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter
success "Kernel modules loaded (overlay, br_netfilter)"

# ==============================================================================
# Step 3: Set sysctl parameters
# ==============================================================================
log "Step 3: Configuring sysctl parameters..."

cp "$CONFIGS_DIR/sysctl-k8s.conf" /etc/sysctl.d/99-k8s.conf
sysctl --system > /dev/null 2>&1
success "Sysctl parameters applied"

# Verify
for param in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
    val=$(sysctl -n "$param")
    if [[ "$val" != "1" ]]; then
        fail "sysctl $param = $val (expected 1)"
    fi
done
success "All sysctl parameters verified"

# ==============================================================================
# Step 3.5: Install required system dependencies
# ==============================================================================
log "Installing required system dependencies (conntrack, socat, ethtool)..."
pacman -Sy --noconfirm --needed conntrack-tools socat ethtool iproute2
success "System dependencies installed"

# ==============================================================================
# Step 4: Install containerd
# ==============================================================================
log "Step 4: Installing containerd..."

if command -v containerd &>/dev/null; then
    success "containerd already installed: $(containerd --version)"
else
    pacman -Sy --noconfirm containerd
    success "containerd installed"
fi

# Configure containerd — generate from defaults and patch for k8s
mkdir -p /etc/containerd

# Generate default config, then patch required settings
containerd config default > /etc/containerd/config.toml

# Enable SystemdCgroup (required for kubeadm)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Set correct sandbox (pause) image
sed -i "s|sandbox = .*|sandbox = 'registry.k8s.io/pause:3.10'|" /etc/containerd/config.toml

systemctl daemon-reload
systemctl restart containerd
sleep 2

# Verify containerd is running
if systemctl is-active --quiet containerd; then
    success "containerd configured and running"
else
    fail "containerd failed to start. Check: journalctl -u containerd"
fi

# ==============================================================================
# Step 5: Install kubeadm, kubelet, kubectl
# ==============================================================================
log "Step 5: Installing Kubernetes tools..."

# On Arch/CachyOS, these may be in the AUR or community repos
# We install from official Kubernetes repos as static binaries for reliability
KUBE_VERSION="v1.31.0"

install_kube_binary() {
    local name="$1"
    if command -v "$name" &>/dev/null; then
        success "$name already installed: $($name version --client --short 2>/dev/null || $name version 2>/dev/null | head -1)"
        return
    fi
    log "Downloading $name $KUBE_VERSION..."
    curl -LO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/amd64/${name}"
    chmod +x "$name"
    mv "$name" /usr/local/bin/
    success "$name installed"
}

install_kube_binary kubectl
install_kube_binary kubeadm
install_kube_binary kubelet

# Install crictl (required by kubelet)
if ! command -v crictl &>/dev/null; then
    log "Installing crictl..."
    CRICTL_VERSION="v1.31.0"
    curl -LO "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
    tar zxvf "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" -C /usr/local/bin
    rm -f "crictl-${CRICTL_VERSION}-linux-amd64.tar.gz"
    success "crictl installed"
else
    success "crictl already installed"
fi

# Configure crictl to use containerd
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# Install CNI plugins (required for pod networking)
if [[ ! -d /opt/cni/bin ]] || [[ -z "$(ls -A /opt/cni/bin 2>/dev/null)" ]]; then
    log "Installing CNI plugins..."
    CNI_VERSION="v1.6.0"
    CNI_TARBALL="cni-plugins-linux-amd64-${CNI_VERSION}.tgz"
    mkdir -p /opt/cni/bin
    curl -L --fail -o "$CNI_TARBALL" \
        "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/${CNI_TARBALL}"
    tar zxvf "$CNI_TARBALL" -C /opt/cni/bin
    rm -f "$CNI_TARBALL"
    success "CNI plugins installed in /opt/cni/bin"
else
    success "CNI plugins already present"
fi

# ==============================================================================
# Step 6: Setup kubelet systemd service
# ==============================================================================
log "Step 6: Configuring kubelet service..."

mkdir -p /etc/systemd/system/kubelet.service.d

cat > /etc/systemd/system/kubelet.service <<'EOF'
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
Wants=containerd.service
After=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<'EOF'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF

systemctl daemon-reload
systemctl enable kubelet
success "kubelet service configured"

# ==============================================================================
# Step 7: Initialize cluster with kubeadm
# ==============================================================================
log "Step 7: Initializing Kubernetes cluster with kubeadm..."

# Pull images first
log "Pulling required container images..."
kubeadm config images pull --config "$CONFIGS_DIR/kubeadm-config.yaml" || \
    kubeadm config images pull

# Initialize the cluster
kubeadm init --config "$CONFIGS_DIR/kubeadm-config.yaml" --skip-phases=addon/kube-proxy 2>&1 | tee /tmp/kubeadm-init.log || \
    kubeadm init --pod-network-cidr=10.244.0.0/16 2>&1 | tee /tmp/kubeadm-init.log

success "kubeadm init completed"

# ==============================================================================
# Step 8: Configure kubectl for the invoking user
# ==============================================================================
log "Step 8: Configuring kubectl access..."

# For root
mkdir -p "$HOME/.kube"
cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# Also configure for the user who invoked sudo
if [[ -n "${SUDO_USER:-}" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    mkdir -p "$USER_HOME/.kube"
    cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
    chown "$(id -u "$SUDO_USER"):$(id -g "$SUDO_USER")" "$USER_HOME/.kube/config"
    success "kubectl configured for user $SUDO_USER"
fi

success "kubectl configured for root"

# ==============================================================================
# Step 9: Install kube-proxy (since we skipped it during init)
# ==============================================================================
log "Step 9: Installing kube-proxy..."
kubeadm init phase addon kube-proxy --config "$CONFIGS_DIR/kubeadm-config.yaml" 2>/dev/null || \
    kubeadm init phase addon kube-proxy 2>/dev/null || true
success "kube-proxy addon installed"

# ==============================================================================
# Step 10: Remove control-plane taint (single-node scheduling)
# ==============================================================================
log "Step 10: Removing control-plane taint for single-node scheduling..."

kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
success "Control-plane taint removed — pods can now be scheduled on this node"

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "============================================================"
echo -e "${GREEN}🎉 Bare-metal Kubernetes cluster initialized!${NC}"
echo "============================================================"
echo ""
echo "Node status:"
kubectl get nodes -o wide
echo ""
echo "⚠️  Node will show 'NotReady' until a CNI is installed."
echo ""
echo "Next steps:"
echo "  1. Install a CNI plugin:"
echo "     sudo bash $SCRIPT_DIR/install_flannel.sh"
echo "     sudo bash $SCRIPT_DIR/install_calico.sh"
echo "     sudo bash $SCRIPT_DIR/install_cilium.sh"
echo ""
echo "  2. Deploy workloads:"
echo "     bash $SCRIPT_DIR/deploy_workload.sh"
echo ""
