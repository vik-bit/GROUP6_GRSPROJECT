# CNI Benchmark — Kind Implementation
# Usage: make <target> | make help

PROJECT_ROOT  := $(shell pwd)
SCRIPTS_DIR   := $(PROJECT_ROOT)/scripts
MANIFESTS_DIR := $(PROJECT_ROOT)/k8s-manifests
MICROSVCS_DIR := $(PROJECT_ROOT)/microservices
LOAD_TEST_DIR := $(PROJECT_ROOT)/load-test
PLOTS_DIR     := $(PROJECT_ROOT)/plots

CLUSTER_NAME  ?= cni-benchmark
IMAGE_NAME    ?= microservice:latest
KIND_NODE_IMG ?= kindest/node:v1.29.2
USER_LEVELS   ?= 50 100 200 300 400
SPAWN_RATE    ?= 10
RUN_TIME      ?= 1m

RESULTS_FILE    := $(PROJECT_ROOT)/results.csv
CALICO_RESULTS  := $(PROJECT_ROOT)/calicoresults.csv
FLANNEL_RESULTS := $(PROJECT_ROOT)/flannelresults.csv
CILIUM_RESULTS  := $(PROJECT_ROOT)/ciliumresults.csv

.PHONY: help \
        setup-calico setup-flannel setup-cilium \
        build load-image \
        deploy-services undeploy-services \
        port-forward \
        install-monitoring \
        run-locust collect-metrics \
        plot \
        clean clean-results clean-cluster \
        check-deps \
        all-calico all-flannel all-cilium

.DEFAULT_GOAL := help

help:
	@echo ""
	@echo "╔══════════════════════════════════════════════════════════════╗"
	@echo "║         CNI Benchmark — Kind Implementation — Makefile       ║"
	@echo "╚══════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "  Cluster Setup (full pipeline per CNI):"
	@echo "    make setup-calico       — Full Calico cluster setup + benchmark"
	@echo "    make setup-flannel      — Full Flannel cluster setup + benchmark"
	@echo "    make setup-cilium       — Full Cilium cluster setup + benchmark"
	@echo ""
	@echo "  Step-by-step targets:"
	@echo "    make check-deps         — Verify required tools are available"
	@echo "    make build              — Build the microservice Docker image"
	@echo "    make load-image         — Load the image into the Kind cluster"
	@echo "    make deploy-services    — Apply all K8s manifests"
	@echo "    make undeploy-services  — Delete all K8s manifests"
	@echo "    make port-forward       — Port-forward service-a → localhost:8080"
	@echo "    make install-monitoring — Install Prometheus + Grafana via Helm"
	@echo "    make run-locust         — Run Locust load tests (all user levels)"
	@echo "    make collect-metrics    — Run metrics.sh for an explicit user count"
	@echo "                              (e.g. make collect-metrics USERS=100)"
	@echo ""
	@echo "  Shorthand full pipelines (no cluster teardown between steps):"
	@echo "    make all-calico         — Alias for setup-calico"
	@echo "    make all-flannel        — Alias for setup-flannel"
	@echo "    make all-cilium         — Alias for setup-cilium"
	@echo ""
	@echo "  Analysis:"
	@echo "    make plot               — Run all Python plotting scripts"
	@echo ""
	@echo "  Cleanup:"
	@echo "    make clean              — Delete Kind cluster + Docker artifacts"
	@echo "    make clean-results      — Remove all results CSV files"
	@echo "    make clean-cluster      — Delete only the Kind cluster (keep images)"
	@echo ""
	@echo "  Override variables:"
	@echo "    CLUSTER_NAME   (default: $(CLUSTER_NAME))"
	@echo "    IMAGE_NAME     (default: $(IMAGE_NAME))"
	@echo "    KIND_NODE_IMG  (default: $(KIND_NODE_IMG))"
	@echo "    USER_LEVELS    (default: $(USER_LEVELS))"
	@echo "    SPAWN_RATE     (default: $(SPAWN_RATE))"
	@echo "    RUN_TIME       (default: $(RUN_TIME))"
	@echo ""

check-deps:
	@echo "🔍 Checking required tools..."
	@command -v docker   >/dev/null 2>&1 || { echo "❌  docker   not found"; exit 1; }
	@command -v kind     >/dev/null 2>&1 || { echo "❌  kind     not found"; exit 1; }
	@command -v kubectl  >/dev/null 2>&1 || { echo "❌  kubectl  not found"; exit 1; }
	@command -v helm     >/dev/null 2>&1 || { echo "❌  helm     not found"; exit 1; }
	@command -v jq       >/dev/null 2>&1 || { echo "❌  jq       not found"; exit 1; }
	@command -v locust   >/dev/null 2>&1 || { echo "❌  locust   not found"; exit 1; }
	@echo "✅ All required tools are present"

# Full CNI pipelines — delegate to shell scripts
setup-calico:
	@echo "🚀 Starting full Calico benchmark pipeline..."
	@chmod +x $(SCRIPTS_DIR)/calicosetup.sh
	sudo $(SCRIPTS_DIR)/calicosetup.sh

setup-flannel:
	@echo "🚀 Starting full Flannel benchmark pipeline..."
	@chmod +x $(SCRIPTS_DIR)/flannelsetup.sh
	sudo $(SCRIPTS_DIR)/flannelsetup.sh

setup-cilium:
	@echo "🚀 Starting full Cilium benchmark pipeline..."
	@chmod +x $(SCRIPTS_DIR)/ciliumsetup.sh
	sudo $(SCRIPTS_DIR)/ciliumsetup.sh

all-calico:  setup-calico
all-flannel: setup-flannel
all-cilium:  setup-cilium

build:
	@echo "🐳 Building microservice image: $(IMAGE_NAME)"
	docker build -t $(IMAGE_NAME) $(MICROSVCS_DIR)
	@echo "✅ Image built: $(IMAGE_NAME)"

load-image: build
	@echo "📦 Loading $(IMAGE_NAME) into Kind cluster '$(CLUSTER_NAME)'..."
	kind load docker-image $(IMAGE_NAME) --name $(CLUSTER_NAME)
	@echo "✅ Image loaded into cluster"

deploy-services:
	@echo "🚀 Deploying microservices..."
	kubectl apply -f $(MANIFESTS_DIR)/service-c.yaml
	kubectl apply -f $(MANIFESTS_DIR)/service-c-svc.yaml
	kubectl wait --for=condition=Ready pod -l app=service-c --timeout=120s
	kubectl apply -f $(MANIFESTS_DIR)/service-b.yaml
	kubectl apply -f $(MANIFESTS_DIR)/service-b-svc.yaml
	kubectl wait --for=condition=Ready pod -l app=service-b --timeout=120s
	kubectl apply -f $(MANIFESTS_DIR)/service-a.yaml
	kubectl wait --for=condition=Ready pod -l app=service-a --timeout=120s
	@echo "✅ All microservices deployed and ready"

undeploy-services:
	@echo "🗑️  Removing microservice deployments..."
	kubectl delete -f $(MANIFESTS_DIR)/ --ignore-not-found=true
	@echo "✅ Microservices removed"

port-forward:
	@echo "🔌 Port-forwarding service-a → localhost:8080 (background)..."
	kubectl port-forward svc/service-a 8080:80 >/dev/null 2>&1 &
	@sleep 3
	@echo "🔍 Testing service chain..."
	@curl -s http://localhost:8080 || echo "⚠️  Service not reachable yet — wait a moment and retry"
	@echo ""

install-monitoring:
	@echo "🔥 Installing Prometheus & Grafana monitoring stack..."
	kubectl create ns monitoring --dry-run=client -o yaml | kubectl apply -f -
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	helm repo update
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
	    -n monitoring --wait
	kubectl wait --for=condition=Ready pod -n monitoring --all --timeout=300s
	@echo "✅ Monitoring stack deployed"

run-locust:
	@echo "🦗 Starting Locust load tests..."
	@if [ ! -f "$(RESULTS_FILE)" ]; then \
	    echo "Timestamp,Users,Requestpersec,Percentile95_latency_ms,Cpu_pods,Memory_pods,Cpu_nodes,Memory_nodes,Ping_intra_ms,Ping_inter_ms,Bandwidth_mbps" \
	        > "$(RESULTS_FILE)"; \
	fi
	@export PATH="$$PATH:$$HOME/.local/bin"; \
	cd $(LOAD_TEST_DIR); \
	for USERS in $(USER_LEVELS); do \
	    echo "🚀 Running test with $$USERS users"; \
	    locust -f locustfile.py \
	        --host=http://localhost:8080 \
	        --headless \
	        -u $$USERS \
	        -r $(SPAWN_RATE) \
	        --run-time $(RUN_TIME) \
	        --csv=locust_stats; \
	    sudo $(SCRIPTS_DIR)/metrics.sh $$USERS; \
	done
	@echo "🎉 Locust tests complete! Results in $(RESULTS_FILE)"

USERS ?= 100
collect-metrics:
	@echo "📊 Collecting metrics for $(USERS) users..."
	@chmod +x $(SCRIPTS_DIR)/metrics.sh
	sudo $(SCRIPTS_DIR)/metrics.sh $(USERS)

plot:
	@echo "📈 Generating plots..."
	@cd $(PLOTS_DIR) && \
	    for script in *.py; do \
	        echo "  Running $$script..."; \
	        python3 "$$script" || echo "  ⚠️  $$script failed (continuing)"; \
	    done
	@echo "✅ Plots generated in $(PLOTS_DIR)"

clean:
	@echo "🧹 Deleting Kind cluster '$(CLUSTER_NAME)' and Docker artefacts..."
	kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@docker ps -aq | xargs -r docker rm -f 2>/dev/null || true
	docker network prune -f 2>/dev/null || true
	docker system prune -af 2>/dev/null || true
	@echo "✅ Cleanup complete"

clean-cluster:
	@echo "🧹 Deleting Kind cluster '$(CLUSTER_NAME)'..."
	kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@echo "✅ Cluster deleted"

clean-results:
	@echo "🗑️  Removing result CSV files..."
	rm -f $(RESULTS_FILE) $(CALICO_RESULTS) $(FLANNEL_RESULTS) $(CILIUM_RESULTS)
	rm -f $(LOAD_TEST_DIR)/locust_stats_*.csv
	@echo "✅ Result files removed"
