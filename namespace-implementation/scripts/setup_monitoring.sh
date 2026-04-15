#!/bin/bash
# ============================================================================
# setup_monitoring.sh — Deploy Prometheus + Grafana monitoring stack
#
# Runs:
#   - node_exporter on host (port 9100) for system metrics
#   - process-exporter on host (port 9256) for per-process metrics
#   - Prometheus (port 9090) — via Docker if available, else native binary
#   - Grafana (port 3000) — via Docker if available, else native binary
#
# Usage: sudo ./setup_monitoring.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"
CONFIGS_DIR="$PROJECT_ROOT/configs"

NODE_EXPORTER_VERSION="1.7.0"
PROCESS_EXPORTER_VERSION="0.7.10"
PROMETHEUS_VERSION="2.50.1"
GRAFANA_VERSION="10.3.3"

MONITORING_DIR="/opt/ns-monitoring"
mkdir -p "$MONITORING_DIR"

echo "============================================"
echo "📊 Setting up monitoring stack..."
echo "============================================"

# -------------------- Step 1: Install node_exporter --------------------
echo "📌 Setting up node_exporter..."

if [ ! -f /usr/local/bin/node_exporter ]; then
    echo "  Downloading node_exporter v${NODE_EXPORTER_VERSION}..."
    cd /tmp
    wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" -O node_exporter.tar.gz
    tar xf node_exporter.tar.gz
    cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
    rm -rf node_exporter.tar.gz "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64"
    cd "$SCRIPT_DIR"
fi

pkill -f "node_exporter" 2>/dev/null || true
sleep 1

echo "  Starting node_exporter on :9100..."
nohup /usr/local/bin/node_exporter --web.listen-address=":9100" > /tmp/node_exporter.log 2>&1 &
sleep 2

if curl -s http://localhost:9100/metrics > /dev/null 2>&1; then
    echo "  ✅ node_exporter running on :9100"
else
    echo "  ⚠️  node_exporter may not be ready yet (check /tmp/node_exporter.log)"
fi

# -------------------- Step 2: Install process-exporter --------------------
echo "📌 Setting up process-exporter..."

if [ ! -f /usr/local/bin/process-exporter ]; then
    echo "  Downloading process-exporter v${PROCESS_EXPORTER_VERSION}..."
    cd /tmp
    wget -q "https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/process-exporter-${PROCESS_EXPORTER_VERSION}.linux-amd64.tar.gz" -O process-exporter.tar.gz
    tar xf process-exporter.tar.gz
    cp "process-exporter-${PROCESS_EXPORTER_VERSION}.linux-amd64/process-exporter" /usr/local/bin/
    rm -rf process-exporter.tar.gz "process-exporter-${PROCESS_EXPORTER_VERSION}.linux-amd64"
    cd "$SCRIPT_DIR"
fi

pkill -f "process-exporter" 2>/dev/null || true
sleep 1

echo "  Starting process-exporter on :9256..."
nohup /usr/local/bin/process-exporter \
    --config.path="$CONFIGS_DIR/process-exporter.yml" \
    --web.listen-address=":9256" > /tmp/process_exporter.log 2>&1 &
sleep 2

if curl -s http://localhost:9256/metrics > /dev/null 2>&1; then
    echo "  ✅ process-exporter running on :9256"
else
    echo "  ⚠️  process-exporter may not be ready yet (check /tmp/process_exporter.log)"
fi

# -------------------- Detect Docker --------------------
USE_DOCKER=false
if command -v docker &>/dev/null; then
    if ! docker info &>/dev/null 2>&1; then
        echo ""
        echo "📌 Docker found but not running. Starting Docker..."
        systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
        sleep 3
    fi
    if docker info &>/dev/null 2>&1; then
        USE_DOCKER=true
        echo "  ✅ Docker is available"
    else
        echo "  ⚠️  Could not start Docker, falling back to native binaries"
    fi
else
    echo "  ℹ️  Docker not installed, using native binaries"
fi

# -------------------- Step 3: Run Prometheus --------------------
echo "📌 Setting up Prometheus..."

if [ "$USE_DOCKER" = true ]; then
    docker rm -f prometheus 2>/dev/null || true

    docker run -d \
        --name prometheus \
        --network host \
        -v "$CONFIGS_DIR/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
        prom/prometheus:latest \
        --config.file=/etc/prometheus/prometheus.yml \
        --web.listen-address=":9090" \
        --storage.tsdb.retention.time=1d
else
    # Native Prometheus
    if [ ! -f "$MONITORING_DIR/prometheus" ]; then
        echo "  Downloading Prometheus v${PROMETHEUS_VERSION}..."
        cd /tmp
        wget -q "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" -O prometheus.tar.gz
        tar xf prometheus.tar.gz
        cp "prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus" "$MONITORING_DIR/"
        cp "prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool" "$MONITORING_DIR/"
        rm -rf prometheus.tar.gz "prometheus-${PROMETHEUS_VERSION}.linux-amd64"
        cd "$SCRIPT_DIR"
    fi

    pkill -f "$MONITORING_DIR/prometheus" 2>/dev/null || true
    sleep 1

    mkdir -p "$MONITORING_DIR/data"
    nohup "$MONITORING_DIR/prometheus" \
        --config.file="$CONFIGS_DIR/prometheus.yml" \
        --web.listen-address=":9090" \
        --storage.tsdb.path="$MONITORING_DIR/data" \
        --storage.tsdb.retention.time=1d \
        > /tmp/prometheus.log 2>&1 &
fi

echo "  ⏳ Waiting for Prometheus..."
for i in $(seq 1 30); do
    if curl -s http://localhost:9090/-/ready 2>/dev/null | grep -qi "prometheus\|ready"; then
        echo "  ✅ Prometheus ready on :9090"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ⚠️  Prometheus may still be starting (check http://localhost:9090)"
    fi
    sleep 2
done

# -------------------- Step 4: Run Grafana --------------------
echo "📌 Setting up Grafana..."

if [ "$USE_DOCKER" = true ]; then
    docker rm -f grafana 2>/dev/null || true

    GRAFANA_PROV_DIR="/tmp/grafana-provisioning/datasources"
    mkdir -p "$GRAFANA_PROV_DIR"

    cat > "$GRAFANA_PROV_DIR/prometheus.yml" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: true
EOF

    docker run -d \
        --name grafana \
        --network host \
        -v "$GRAFANA_PROV_DIR:/etc/grafana/provisioning/datasources:ro" \
        -e "GF_SECURITY_ADMIN_PASSWORD=admin" \
        -e "GF_AUTH_ANONYMOUS_ENABLED=true" \
        grafana/grafana:latest
else
    # Native Grafana
    if [ ! -f "$MONITORING_DIR/grafana/bin/grafana" ] && [ ! -f "$MONITORING_DIR/grafana/bin/grafana-server" ]; then
        echo "  Downloading Grafana v${GRAFANA_VERSION}..."
        cd /tmp
        wget -q "https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz" -O grafana.tar.gz
        tar xf grafana.tar.gz
        mv "grafana-v${GRAFANA_VERSION}" "$MONITORING_DIR/grafana" 2>/dev/null || \
        mv "grafana-${GRAFANA_VERSION}" "$MONITORING_DIR/grafana" 2>/dev/null || true
        rm -f grafana.tar.gz
        cd "$SCRIPT_DIR"
    fi

    if [ -d "$MONITORING_DIR/grafana" ]; then
        pkill -f "grafana" 2>/dev/null || true
        sleep 1

        # Setup datasource provisioning
        PROV_DIR="$MONITORING_DIR/grafana/conf/provisioning/datasources"
        mkdir -p "$PROV_DIR"
        cat > "$PROV_DIR/prometheus.yml" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    editable: true
EOF

        GRAFANA_BIN=$(find "$MONITORING_DIR/grafana" -name "grafana-server" -o -name "grafana" | head -1)
        if [ -n "$GRAFANA_BIN" ] && [ -x "$GRAFANA_BIN" ]; then
            nohup "$GRAFANA_BIN" \
                --homepath="$MONITORING_DIR/grafana" \
                --config="$MONITORING_DIR/grafana/conf/defaults.ini" \
                web > /tmp/grafana.log 2>&1 &
        else
            # Try the 'grafana server' command
            GRAFANA_BIN=$(find "$MONITORING_DIR/grafana" -name "grafana" -type f | head -1)
            if [ -n "$GRAFANA_BIN" ]; then
                nohup "$GRAFANA_BIN" server \
                    --homepath="$MONITORING_DIR/grafana" \
                    > /tmp/grafana.log 2>&1 &
            else
                echo "  ⚠️  Could not find Grafana binary"
            fi
        fi
    else
        echo "  ⚠️  Grafana download may have failed. Skipping."
    fi
fi

echo "  ⏳ Waiting for Grafana..."
for i in $(seq 1 30); do
    if curl -s http://localhost:3000/api/health 2>/dev/null | grep -q "ok"; then
        echo "  ✅ Grafana ready on :3000 (admin/admin)"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "  ⚠️  Grafana may still be starting (check http://localhost:3000)"
    fi
    sleep 2
done

echo ""
echo "============================================"
echo "✅ Monitoring stack deployed!"
echo ""
echo "  Prometheus: http://localhost:9090"
echo "  Grafana:    http://localhost:3000 (admin/admin)"
echo ""
echo "  node_exporter:    http://localhost:9100/metrics"
echo "  process-exporter: http://localhost:9256/metrics"
echo "============================================"
