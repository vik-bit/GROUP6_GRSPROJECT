#!/bin/bash
# ==============================================================================
# install_calico.sh — Install Calico CNI on the bare-metal cluster
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

# Check if Calico is already running
if kubectl get pods -n kube-system -l k8s-app=calico-node 2>/dev/null | grep -q Running; then
    success "Calico is already running"
    exit 0
fi

# ==============================================================================
# Install Calico
# ==============================================================================
log "Installing Calico CNI..."

# Use the Calico operator method (recommended)
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/tigera-operator.yaml 2>/dev/null || \
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/tigera-operator.yaml

# Apply custom resource with our pod CIDR
cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      blockSize: 26
      cidr: 10.244.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF

log "Waiting for Calico pods to be ready..."
# Wait for the operator to create the calico-system namespace
for i in $(seq 1 30); do
    if kubectl get ns calico-system &>/dev/null; then
        break
    fi
    sleep 2
done

kubectl wait --for=condition=Ready pods \
    -l k8s-app=calico-node \
    -n calico-system \
    --timeout=300s 2>/dev/null || \
kubectl wait --for=condition=Ready pods \
    -l k8s-app=calico-node \
    -n kube-system \
    --timeout=300s 2>/dev/null || true

# Wait for the node to become Ready
log "Waiting for node to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

success "Calico installed and node is Ready"

echo ""
kubectl get nodes -o wide
echo ""
kubectl get pods -n calico-system 2>/dev/null || kubectl get pods -n kube-system -l k8s-app=calico-node 2>/dev/null
echo ""
