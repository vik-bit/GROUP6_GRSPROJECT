#!/bin/bash
set -e

# --------------------------
# Full Reset + Dev Cluster Setup
# --------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
CLUSTER_NAME="cni-benchmark"
CLUSTER_YAML="$PROJECT_ROOT/cluster/cluster.yaml"

echo "🧹 Step 1: Cleanup old Kind cluster and Docker leftovers..."

# Delete old Kind cluster
kind delete cluster --name $CLUSTER_NAME || true

# Remove all containers and prune Docker
docker ps -aq | xargs -r docker rm -f
docker network prune -f
docker system prune -af

echo "✅ Cleanup complete"

# ------------------- Step 2: Validate tools -------------------
for tool in docker kubectl kind; do
    if ! command -v $tool &>/dev/null; then
        echo "❌ $tool not found. Please install it before running this script."
        exit 1
    else
        echo "✅ $tool installed"
    fi
done

# ------------------- Step 3: Pre-pull Kind node image -------------------
echo "⬇️ Pulling Kind node image..."
docker pull kindest/node:v1.29.2

# ------------------- Step 4: Create Kind cluster -------------------
echo "🚀 Creating Kind multi-node cluster..."
kind create cluster --name $CLUSTER_NAME --config "$CLUSTER_YAML" --wait 90s
echo "📦 Copying CNI plugins into Kind nodes..."

echo "📦 Setting up CNI plugins inside Kind nodes..."
for node in $(kind get nodes --name $CLUSTER_NAME); do
    # create the directory if it doesn't exist
    docker exec $node mkdir -p /opt/cni/bin
    # copy all plugins
    docker cp "$PROJECT_ROOT/cluster/cni-plugins/." $node:/opt/cni/bin/
    # make them executable
    docker exec $node chmod +x /opt/cni/bin/
done

for node in $(kind get nodes --name cni-benchmark); do
    echo "⚡ Fixing CNI permissions on $node..."
    docker exec $node sh -c 'chmod +x /opt/cni/bin/*'
done


echo "🔧 Loading kernel modules and sysctl for flannel..."
sudo modprobe br_netfilter
sudo modprobe overlay
sudo sysctl net.bridge.bridge-nf-call-iptables=1
sudo sysctl net.bridge.bridge-nf-call-ip6tables=1

echo "⚠️ Nodes may be NotReady until Flannel is installed"

# ------------------- Step 5: Install Flannel -------------------
echo "🌐 Installing Flannel CNI..."
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# Wait for all nodes to be Ready
echo "⏳ Waiting for all nodes to become Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes -o wide
kubectl get pods -A

# ------------------- Step 6: Build single Docker image -------------------
echo "🐳 Building microservice image..."
docker build -t microservice:latest "$PROJECT_ROOT/microservices"

# ------------------- Step 7: Load image into Kind -------------------
echo "📦 Loading image into Kind..."
kind load docker-image microservice:latest --name $CLUSTER_NAME

# ------------------- Step 8: Deploy Microservices -------------------
echo "🚀 Deploying microservices..."
kubectl apply -f "$PROJECT_ROOT/k8s-manifests/service-c.yaml"
kubectl apply -f "$PROJECT_ROOT/k8s-manifests/service-c-svc.yaml"
kubectl wait --for=condition=Ready pod -l app=service-c --timeout=120s

kubectl apply -f "$PROJECT_ROOT/k8s-manifests/service-b.yaml"
kubectl wait --for=condition=Ready pod -l app=service-b --timeout=120s

kubectl apply -f "$PROJECT_ROOT/k8s-manifests/service-a.yaml"
kubectl wait --for=condition=Ready pod -l app=service-a --timeout=120s

# ------------------- Step 9: Port-forward Service A -------------------
echo "🔌 Port-forwarding Service A to localhost:8080..."
kubectl port-forward svc/service-a 8080:80 > /dev/null 2>&1 &
sleep 5

# ------------------- Step 10: Quick test chain -------------------
echo "🔍 Testing service chain..."
curl http://localhost:8080
echo ""

# ------------------- Step 11: Start Locust load test -------------------
echo "🔥 Starting Locust load test..."
cd "$PROJECT_ROOT/load-tests"
locust -f locust.py --host=http://localhost:8080