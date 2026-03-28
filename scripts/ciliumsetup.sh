#!/bin/bash
set -euo pipefail

trap 'echo "❌ Error at line $LINENO"; exit 1' ERR

# --------------------------
# Config
# --------------------------
CLUSTER_NAME="cni-benchmark"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"
CLUSTER_YAML="$PROJECT_ROOT/cluster/cluster.yaml"
RESULTS_FILE="$PROJECT_ROOT/results.csv"

# --------------------------
# Logging helpers
# --------------------------
log() { echo -e "\n🔹 $1"; }
success() { echo "✅ $1"; }
warn() { echo "⚠️ $1"; }

# --------------------------
# Install helpers
# --------------------------
install_docker() {
    log "Installing Docker..."
    sudo apt update
    sudo apt install -y docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
}

install_kubectl() {
    log "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
}

install_kind() {
    log "Installing kind..."
    curl -Lo kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
    chmod +x kind
    sudo mv kind /usr/local/bin/
}

install_helm() {
    log "Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

install_jq() {
    log "Installing jq..."
    sudo apt update
    sudo apt install -y jq
}

# --------------------------
# Step 1: Ensure dependencies
# --------------------------
log "Checking dependencies..."

command -v docker >/dev/null || install_docker
command -v kubectl >/dev/null || install_kubectl
command -v kind >/dev/null || install_kind
command -v helm >/dev/null || install_helm
command -v jq >/dev/null || install_jq

success "All tools available"

# --------------------------
# Step 2: Ensure Docker running
# --------------------------
if ! docker info >/dev/null 2>&1; then
    warn "Docker not running. Starting..."
    sudo systemctl start docker
fi

# --------------------------
# Step 3: Cleanup (safe)
# --------------------------
log "Cleaning old cluster..."
kind delete cluster --name "$CLUSTER_NAME" || true
success "Old cluster removed"

# --------------------------
# Step 4: Pull base images
# --------------------------
log "Pulling required images..."
docker pull golang:1.21
docker pull kindest/node:v1.29.2

# --------------------------
# Step 5: Create cluster
# --------------------------
log "Creating Kind cluster..."
kind create cluster \
  --name "$CLUSTER_NAME" \
  --config "$CLUSTER_YAML" \
  --wait 120s

success "Cluster created"

# --------------------------
# Step 6: Load images into cluster
# --------------------------
log "Loading images into Kind..."
kind load docker-image golang:1.21 --name "$CLUSTER_NAME"

# --------------------------
# Step 7: Kernel setup
# --------------------------
log "Configuring kernel modules..."
sudo modprobe br_netfilter overlay || true
sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1

# --------------------------
# Step 8: Install Cilium (Helm)
# --------------------------
log "Installing Cilium..."

helm repo add cilium https://helm.cilium.io/ || true
helm repo update

kubectl create namespace kube-system --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install cilium cilium/cilium \
  --version 1.19.1 \
  -n kube-system

# Wait for nodes
log "Waiting for nodes..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# Wait for Cilium pods
log "Waiting for Cilium pods..."
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=cilium --timeout=300s

success "Cilium installed"

# --------------------------
# Step 9: Build app image
# --------------------------
log "Building microservice..."
docker build -t microservice:latest "$PROJECT_ROOT/microservices"
kind load docker-image microservice:latest --name "$CLUSTER_NAME"

# --------------------------
# Step 10: Deploy services
# --------------------------
log "Deploying microservices..."

kubectl apply -f "$PROJECT_ROOT/k8s-manifests/"

kubectl wait --for=condition=Ready pod --all --timeout=180s

# --------------------------
# Step 11: Port forward
# --------------------------
log "Port-forwarding service..."
kubectl port-forward svc/service-a 8080:80 >/dev/null 2>&1 &

sleep 5

log "Testing service..."
curl -s http://localhost:8080 || warn "Service test failed"

# --------------------------
# Step 12: Monitoring stack
# --------------------------
log "Installing Prometheus stack..."

kubectl create ns monitoring --dry-run=client -o yaml | kubectl apply -f -

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo update

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring

success "Monitoring installed"

# --------------------------
# Step 13: Results file
# --------------------------
if [ ! -f "$RESULTS_FILE" ]; then
    echo "Timestamp,Users,RPS,P95_latency,Cpu_pods,Mem_pods,Cpu_nodes,Mem_nodes" > "$RESULTS_FILE"
fi

# --------------------------
# Step 14: Load testing
# --------------------------
log "Starting load tests..."

USER_LEVELS=(50 100 200 300 400)
SPAWN_RATE=10
RUN_TIME="1m"

cd "$PROJECT_ROOT/load-test"

for USERS in "${USER_LEVELS[@]}"; do
    log "Running test: $USERS users"

    locust -f locustfile.py \
      --host=http://localhost:8080 \
      --headless \
      -u "$USERS" \
      -r "$SPAWN_RATE" \
      --run-time "$RUN_TIME" \
      --csv=locust_stats || warn "Locust failed"
done

success "All tests complete 🎉"