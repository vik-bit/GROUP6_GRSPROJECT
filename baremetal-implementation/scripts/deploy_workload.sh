#!/bin/bash
# ==============================================================================
# deploy_workload.sh — Build and deploy the microservice chain (A → B → C)
# Works with containerd (no Docker required for image building)
# ==============================================================================
set -euo pipefail
trap 'echo "❌ Error at line $LINENO"; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"
REPO_ROOT="$(realpath "$PROJECT_ROOT/..")"
MANIFESTS_DIR="$PROJECT_ROOT/manifests"

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

# Check node is Ready
if ! kubectl get nodes | grep -q " Ready"; then
    echo "❌ No Ready nodes found. Install a CNI first."
    exit 1
fi

# ==============================================================================
# Step 1: Build the microservice container image
# ==============================================================================
log "Step 1: Building microservice container image..."

MICROSERVICE_DIR="$REPO_ROOT/microservices"

if [[ ! -f "$MICROSERVICE_DIR/server.go" ]]; then
    echo "❌ server.go not found at $MICROSERVICE_DIR"
    exit 1
fi

# Helper: Configure Docker to NOT mess with iptables (Kubernetes manages them)
setup_docker_no_iptables() {
    sudo mkdir -p /etc/docker
    if [[ ! -f /etc/docker/daemon.json ]] || ! grep -q '"iptables"' /etc/docker/daemon.json 2>/dev/null; then
        echo '{"iptables": false}' | sudo tee /etc/docker/daemon.json > /dev/null
        log "Configured Docker with iptables=false"
    fi
}

# Helper: Restore iptables FORWARD policy (Docker sets it to DROP)
restore_iptables_forward() {
    sudo iptables -P FORWARD ACCEPT 2>/dev/null || true
    log "Restored iptables FORWARD ACCEPT"
}

# Method 1: Use Docker if available AND running
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    setup_docker_no_iptables
    sudo systemctl restart docker 2>/dev/null; sleep 2
    restore_iptables_forward

    log "Building with Docker..."
    docker build -t microservice:latest "$MICROSERVICE_DIR"

    # Export from Docker and import into containerd
    log "Importing image into containerd..."
    docker save microservice:latest | sudo ctr -n k8s.io images import -
    success "Image built and imported via Docker"

    # Stop Docker to prevent ongoing iptables interference
    log "Stopping Docker daemon to avoid iptables conflicts..."
    sudo systemctl stop docker docker.socket 2>/dev/null || true
    restore_iptables_forward

# Method 1b: Docker CLI exists but daemon not running — try starting it
elif command -v docker &>/dev/null; then
    warn "Docker CLI found but daemon not running. Attempting to start..."
    setup_docker_no_iptables
    if sudo systemctl start docker 2>/dev/null; then
        sleep 2
        restore_iptables_forward

        log "Building with Docker..."
        docker build -t microservice:latest "$MICROSERVICE_DIR"
        log "Importing image into containerd..."
        docker save microservice:latest | sudo ctr -n k8s.io images import -
        success "Image built and imported via Docker"

        # Stop Docker after build
        log "Stopping Docker daemon to avoid iptables conflicts..."
        sudo systemctl stop docker docker.socket 2>/dev/null || true
        restore_iptables_forward
    else
        warn "Could not start Docker daemon. Falling back to manual build..."
        DOCKER_FAILED=true
    fi
fi

# Method 2: Use nerdctl if available (containerd native)
if [[ "${DOCKER_FAILED:-}" == "true" ]] || { ! command -v docker &>/dev/null && command -v nerdctl &>/dev/null; }; then
    if command -v nerdctl &>/dev/null; then
        log "Building with nerdctl..."
        sudo nerdctl build -t docker.io/library/microservice:latest "$MICROSERVICE_DIR" -n k8s.io
        success "Image built with nerdctl"
        DOCKER_FAILED=""
    fi
fi

# Method 3: Build Go binary locally, create OCI image, import into containerd
if [[ "${DOCKER_FAILED:-}" == "true" ]] || { ! command -v docker &>/dev/null && ! command -v nerdctl &>/dev/null; }; then
    log "Building Go binary locally and importing into containerd..."

    if ! command -v go &>/dev/null; then
        echo "❌ Go is required for manual build. Install Go or start Docker."
        exit 1
    fi

    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT

    cp "$MICROSERVICE_DIR/server.go" "$TMPDIR/"
    cd "$TMPDIR"
    go mod init app
    go mod tidy
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o server server.go
    success "Go binary built"

    # Pull a base alpine image into containerd if not present
    if ! sudo ctr -n k8s.io images ls -q | grep -q "alpine:3.19"; then
        log "Pulling alpine:3.19 base image..."
        sudo ctr -n k8s.io images pull docker.io/library/alpine:3.19
    fi

    # Create a Dockerfile and use buildctl or a simple approach:
    # Build with ctr by creating a snapshot, copying files, and committing
    log "Creating container image from binary..."

    # Create a container from alpine, copy our binary, commit as new image
    sudo ctr -n k8s.io run --rm --mount type=bind,src=$TMPDIR/server,dst=/app/server,options=rbind:ro \
        docker.io/library/alpine:3.19 build-helper /bin/sh -c "echo ready" 2>/dev/null || true

    # Alternative: use Dockerfile with buildkit if available
    if command -v buildctl &>/dev/null; then
        log "Using buildkit..."
    fi

    # Simplest working approach: create a minimal OCI tarball
    cat > "$TMPDIR/Dockerfile" <<'INNEREOF'
FROM alpine:3.19
WORKDIR /app
COPY server /app/server
RUN chmod +x /app/server
EXPOSE 8080
CMD ["/app/server"]
INNEREOF

    # Try nerdctl one more time, or use buildah, or give instructions
    if command -v nerdctl &>/dev/null; then
        sudo nerdctl build -t docker.io/library/microservice:latest "$TMPDIR" -n k8s.io
    elif command -v buildah &>/dev/null; then
        buildah bud -t microservice:latest "$TMPDIR"
        buildah push microservice:latest oci-archive:/tmp/microservice.tar
        sudo ctr -n k8s.io images import /tmp/microservice.tar
    else
        echo ""
        echo "❌ Cannot build container image without Docker, nerdctl, or buildah."
        echo "   Please start Docker:  sudo systemctl start docker"
        echo "   Or install nerdctl:   sudo pacman -S nerdctl"
        exit 1
    fi

    cd "$SCRIPT_DIR"
    success "Image built and imported"
fi

# ==============================================================================
# Step 2: Verify image is available in containerd
# ==============================================================================
log "Step 2: Verifying image in containerd..."

if crictl images | grep -q "microservice"; then
    success "Image 'microservice:latest' is available in containerd"
else
    # Try listing with ctr
    if ctr -n k8s.io images ls | grep -q "microservice"; then
        success "Image 'microservice:latest' is available in containerd"
    else
        warn "Image may not be visible yet. Proceeding anyway..."
    fi
fi

# ==============================================================================
# Step 3: Deploy microservices
# ==============================================================================
log "Step 3: Deploying microservice chain..."

# Deploy in reverse order (C first, then B, then A)
kubectl apply -f "$MANIFESTS_DIR/service-c.yaml"
log "Waiting for service-c..."
kubectl wait --for=condition=Ready pod -l app=service-c --timeout=120s

kubectl apply -f "$MANIFESTS_DIR/service-b.yaml"
log "Waiting for service-b..."
kubectl wait --for=condition=Ready pod -l app=service-b --timeout=120s

kubectl apply -f "$MANIFESTS_DIR/service-a.yaml"
log "Waiting for service-a..."
kubectl wait --for=condition=Ready pod -l app=service-a --timeout=120s

success "All services deployed and ready"

# ==============================================================================
# Step 4: Port-forward and test
# ==============================================================================
log "Step 4: Setting up port-forward and testing..."

# Kill existing port-forwards
pkill -f "kubectl port-forward svc/service-a" 2>/dev/null || true
sleep 1

# Start port-forward
kubectl port-forward svc/service-a 8080:80 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

# Test the chain
log "Testing service chain..."
RESPONSE=$(curl -s http://localhost:8080 2>/dev/null || echo "FAILED")

if [[ "$RESPONSE" == *"service-c"* ]]; then
    success "Service chain working: $RESPONSE"
else
    warn "Service chain test returned: $RESPONSE"
    warn "The chain may need more time to initialize"
fi

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "============================================================"
echo -e "${GREEN}🎉 Microservice chain deployed!${NC}"
echo "============================================================"
echo ""
echo "Services:"
kubectl get pods -o wide
echo ""
kubectl get svc
echo ""
echo "Port-forward: localhost:8080 → service-a"
echo "Test: curl http://localhost:8080"
echo ""
