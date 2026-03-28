#!/bin/bash
set -euo pipefail

# --------------------------
# Full Reset + Dev Cluster Setup (Calico)
# --------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"
CLUSTER_NAME="cni-benchmark"
CLUSTER_YAML="$PROJECT_ROOT/cluster/cluster.yaml"
RESULTS_FILE="$PROJECT_ROOT/results.csv"

# ------------------- Step 1: Cleanup -------------------
echo "🧹 Cleaning up old Kind cluster and Docker artifacts..."
kind delete cluster --name "$CLUSTER_NAME" || true
docker ps -aq | xargs -r docker rm -f
docker network prune -f
docker system prune -af
echo "✅ Cleanup complete"

# ------------------- Step 2: Validate tools -------------------
for tool in docker kubectl kind helm jq; do
    if ! command -v "$tool" &>/dev/null; then
        echo "❌ $tool not found. Install it before running."
        exit 1
    else
        echo "✅ $tool installed"
    fi
done

# ------------------- Step 3: Pull Kind image -------------------
echo "⬇️ Pulling Kind node image..."
docker pull kindest/node:v1.29.2

# ------------------- Step 4: Create Kind cluster -------------------
echo "🚀 Creating Kind multi-node cluster..."
kind create cluster --name "$CLUSTER_NAME" --config "$CLUSTER_YAML" --wait 90s

# ------------------- Step 5: Setup CNI plugins -------------------
echo "📦 Copying Calico CNI plugins into Kind nodes..."
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    docker exec "$node" mkdir -p /opt/cni/bin
    # Copy each binary individually if exists
    for plugin in "$PROJECT_ROOT/cluster/cni-plugins/"*; do
        if [ -f "$plugin" ]; then
            docker cp "$plugin" "$node":/opt/cni/bin/
        fi
    done
    docker exec "$node" chmod +x /opt/cni/bin/* || echo "⚠️ No binaries found to chmod"
done

# ------------------- Step 6: Load kernel modules & sysctl -------------------
echo "🔧 Loading kernel modules for networking..."
sudo modprobe br_netfilter overlay
sudo sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-ip6tables=1

# ------------------- Step 7: Install Calico CNI -------------------
echo "🌐 Installing Calico CNI..."
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

echo "⏳ Waiting for all nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes -o wide

# ------------------- Step 8: Build & Load Docker images -------------------
echo "🐳 Building microservice image..."
docker build -t microservice:latest "$PROJECT_ROOT/microservices"
kind load docker-image microservice:latest --name "$CLUSTER_NAME"

# ------------------- Step 9: Deploy Microservices -------------------
echo "🚀 Deploying microservices..."
kubectl apply -f "$PROJECT_ROOT/k8s-manifests/service-c.yaml"
kubectl apply -f "$PROJECT_ROOT/k8s-manifests/service-c-svc.yaml"
kubectl wait --for=condition=Ready pod -l app=service-c --timeout=120s

kubectl apply -f "$PROJECT_ROOT/k8s-manifests/service-b.yaml"
kubectl apply -f "$PROJECT_ROOT/k8s-manifests/service-b-svc.yaml"
kubectl wait --for=condition=Ready pod -l app=service-b --timeout=120s

kubectl apply -f "$PROJECT_ROOT/k8s-manifests/service-a.yaml"
kubectl wait --for=condition=Ready pod -l app=service-a --timeout=120s

# ------------------- Step 10: Port-forward Service A -------------------
echo "🔌 Port-forwarding Service A to localhost:8080..."
kubectl port-forward svc/service-a 8080:80 > /dev/null 2>&1 &
sleep 5

echo "🔍 Testing service chain..."
curl -s http://localhost:8080
echo ""

# ------------------- Step 11: Helm + Prometheus/Grafana (Dynamic) -------------------
echo "🔥 Installing Prometheus & Grafana..."
kubectl create ns monitoring --dry-run=client -o yaml | kubectl apply -f -

# Add repo and update (increase timeout to avoid network issues)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update --timeout 60s

# Install or upgrade kube-prometheus-stack
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring --wait || echo "✅ Already installed"

echo "⏳ Waiting for all pods in monitoring namespace to be Ready..."
kubectl wait --for=condition=Ready pod -n monitoring --all --timeout=300s

# ------------------- Prometheus -------------------
# Dynamically find Prometheus pod
PROM_POD=$(kubectl get pods -n monitoring -o jsonpath='{.items[?(@.metadata.name contains "prometheus")].metadata.name}' | head -n1)

if [[ -z "$PROM_POD" ]]; then
    echo "❌ Prometheus pod not found!"
else
    echo "📊 Prometheus pod: $PROM_POD"
    kubectl port-forward -n monitoring "$PROM_POD" 9090:9090 > /dev/null 2>&1 &
    export PROM_URL="http://localhost:9090"
    echo "✅ Prometheus port-forwarded to localhost:9090"
fi

# ------------------- Grafana -------------------
# Dynamically find Grafana pod
GRAFANA_POD=$(kubectl get pods -n monitoring -o jsonpath='{.items[?(@.metadata.name contains "grafana")].metadata.name}' | head -n1)

if [[ -z "$GRAFANA_POD" ]]; then
    echo "❌ Grafana pod not found!"
else
    echo "📊 Grafana pod: $GRAFANA_POD"
    kubectl port-forward -n monitoring "$GRAFANA_POD" 3000:3000 > /dev/null 2>&1 &
    echo "✅ Grafana port-forwarded to localhost:3000"

    # Try to get Grafana admin password dynamically
    GRAFANA_PASS=$(kubectl get secret -n monitoring "$GRAFANA_POD" -o jsonpath="{.data.admin-password}" 2>/dev/null || \
    kubectl get secret -n monitoring -l app.kubernetes.io/component=admin-secret -o jsonpath="{.items[0].data.admin-password}")
    GRAFANA_PASS=$(echo "$GRAFANA_PASS" | base64 --decode)
    echo "🔑 Grafana admin password: $GRAFANA_PASS"
fi

# ------------------- Step 12: CSV header setup -------------------
if [ ! -f "$RESULTS_FILE" ]; then
    echo "Timestamp,Users,Requestpersec,Percentile95_latency_ms,Cpu_pods,Memory_pods,Cpu_nodes,Memory_nodes,Ping_intra_ms,Ping_inter_ms,Bandwidth_mbps" > "$RESULTS_FILE"
fi

# ------------------- Step 13: Locust load tests -------------------
USER_LEVELS=(50 100 200 300 400)
SPAWN_RATE=10
RUN_TIME="1m"

LOCUST_DIR="$PROJECT_ROOT/load-test"
export PATH="$PATH:$HOME/.local/bin"
sed -i '1i Timestamp,Users,Requestpersec,Percentile95_latency_ms,Cpu_pods,Memory_pods,Cpu_nodes,Memory_nodes,Ping_intra_ms,Ping_inter_ms,Bandwidth_mbps' $RESULTS_FILE

cd "$LOCUST_DIR"
for USERS in "${USER_LEVELS[@]}"; do
    echo "========================================"
    echo "🚀 Running test with $USERS users"
    echo "========================================"

    locust -f locustfile.py \
      --host=http://localhost:8080 \
      --headless \
      -u "$USERS" \
      -r "$SPAWN_RATE" \
      --run-time "$RUN_TIME" \
      --csv=locust_stats

    echo "📊 Collecting metrics..."
    sudo "$PROJECT_ROOT/scripts/metrics.sh" "$USERS"
done

echo "🎉 All tests complete!"