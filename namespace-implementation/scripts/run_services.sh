#!/bin/bash
# ============================================================================
# run_services.sh — Compile and launch C microservices inside namespaces
#
# Assumes setup_topology.sh has already been run.
#
# Service chain:
#   Client → Service A (10.0.1.2:8080)
#          → Service B (10.0.1.3:8080)
#          → Service C (10.0.2.2:8080) [terminal]
#
# Usage: sudo ./run_services.sh
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"
SRC_DIR="$PROJECT_ROOT/src"
BINARY="$SRC_DIR/service"

# -------------------- IP Configuration --------------------
SVC_A_IP="10.0.1.2"
SVC_B_IP="10.0.1.3"
SVC_C_IP="10.0.2.2"

# -------------------- Step 1: Compile --------------------
echo "📌 Compiling C microservice..."

if [ ! -f "$BINARY" ] || [ "$SRC_DIR/service.c" -nt "$BINARY" ]; then
    make -C "$SRC_DIR" clean all
    echo "  ✅ Binary compiled: $BINARY"
else
    echo "  ✅ Binary up to date: $BINARY"
fi

if [ ! -f "$BINARY" ]; then
    echo "❌ Build failed! Binary not found at $BINARY"
    exit 1
fi

# -------------------- Step 2: Verify topology --------------------
echo "📌 Verifying namespaces exist..."

for ns in ns-svc-a ns-svc-b ns-svc-c; do
    if ! ip netns list | grep -q "^${ns}\b"; then
        echo "❌ Namespace $ns not found. Run setup_topology.sh first!"
        exit 1
    fi
done
echo "  ✅ All namespaces present"

# -------------------- Step 3: Kill any old service processes --------------------
echo "📌 Stopping any old service processes..."
for ns in ns-svc-a ns-svc-b ns-svc-c; do
    pids=$(ip netns pids "$ns" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        for pid in $pids; do
            kill -9 "$pid" 2>/dev/null || true
        done
    fi
done
sleep 1
echo "  ✅ Old processes cleaned"

# -------------------- Step 4: Launch services (in order: C, B, A) --------------------
echo "📌 Launching services..."

# Service C (terminal — no NEXT_SERVICE)
echo "  Starting service-c in ns-svc-c ($SVC_C_IP:8080)..."
ip netns exec ns-svc-c env \
    SERVICE_NAME="service-c" \
    NEXT_SERVICE="" \
    "$BINARY" > /tmp/ns-svc-c.log 2>&1 &
SVC_C_PID=$!
sleep 2

# Verify service-c is running
if ! kill -0 $SVC_C_PID 2>/dev/null; then
    echo "  ❌ service-c failed to start! Log:"
    cat /tmp/ns-svc-c.log
    exit 1
fi
echo "  ✅ service-c running (PID=$SVC_C_PID)"

# Service B (forwards to C)
echo "  Starting service-b in ns-svc-b ($SVC_B_IP:8080)..."
ip netns exec ns-svc-b env \
    SERVICE_NAME="service-b" \
    NEXT_SERVICE="http://${SVC_C_IP}:8080" \
    "$BINARY" > /tmp/ns-svc-b.log 2>&1 &
SVC_B_PID=$!
sleep 2

if ! kill -0 $SVC_B_PID 2>/dev/null; then
    echo "  ❌ service-b failed to start! Log:"
    cat /tmp/ns-svc-b.log
    exit 1
fi
echo "  ✅ service-b running (PID=$SVC_B_PID)"

# Service A (forwards to B)
echo "  Starting service-a in ns-svc-a ($SVC_A_IP:8080)..."
ip netns exec ns-svc-a env \
    SERVICE_NAME="service-a" \
    NEXT_SERVICE="http://${SVC_B_IP}:8080" \
    "$BINARY" > /tmp/ns-svc-a.log 2>&1 &
SVC_A_PID=$!
sleep 2

if ! kill -0 $SVC_A_PID 2>/dev/null; then
    echo "  ❌ service-a failed to start! Log:"
    cat /tmp/ns-svc-a.log
    exit 1
fi
echo "  ✅ service-a running (PID=$SVC_A_PID)"

# Save PIDs for cleanup
echo "$SVC_A_PID $SVC_B_PID $SVC_C_PID" > /tmp/ns-service-pids

echo ""
echo "  Services launched:"
echo "    service-c PID=$SVC_C_PID (ns-svc-c @ $SVC_C_IP:8080)"
echo "    service-b PID=$SVC_B_PID (ns-svc-b @ $SVC_B_IP:8080)"
echo "    service-a PID=$SVC_A_PID (ns-svc-a @ $SVC_A_IP:8080)"

# -------------------- Step 5: Diagnostics --------------------
echo ""
echo "📌 Running diagnostics..."

# Check listening ports in each namespace
for ns in ns-svc-c ns-svc-b ns-svc-a; do
    echo -n "  $ns listening on :8080? "
    if ip netns exec "$ns" ss -tlnp 2>/dev/null | grep -q ":8080"; then
        echo "✅"
    else
        echo "❌ NOT LISTENING"
        echo "    Process check:"
        ip netns exec "$ns" ss -tlnp 2>/dev/null || true
    fi
done

# -------------------- Step 6: Test service chain --------------------
echo ""
echo "📌 Testing service chain..."

# Test 1: service-c direct (within namespace)
echo -n "  [1] service-c direct (ns-svc-c → 127.0.0.1:8080): "
RESP_C=$(ip netns exec ns-svc-c curl -s --max-time 5 "http://127.0.0.1:8080/" 2>&1 || echo "CURL_FAILED")
echo "$RESP_C"

# Test 2: service-c from its own IP
echo -n "  [2] service-c via IP (ns-svc-c → $SVC_C_IP:8080): "
RESP_C2=$(ip netns exec ns-svc-c curl -s --max-time 5 "http://${SVC_C_IP}:8080/" 2>&1 || echo "CURL_FAILED")
echo "$RESP_C2"

# Test 3: service-b direct
echo -n "  [3] service-b direct (ns-svc-b → 127.0.0.1:8080): "
RESP_B_LO=$(ip netns exec ns-svc-b curl -s --max-time 10 "http://127.0.0.1:8080/" 2>&1 || echo "CURL_FAILED")
echo "$RESP_B_LO"

# Test 4: service-b via its IP
echo -n "  [4] service-b via IP (ns-svc-b → $SVC_B_IP:8080): "
RESP_B=$(ip netns exec ns-svc-b curl -s --max-time 10 "http://${SVC_B_IP}:8080/" 2>&1 || echo "CURL_FAILED")
echo "$RESP_B"

# Test 5: service-a direct
echo -n "  [5] service-a direct (ns-svc-a → 127.0.0.1:8080): "
RESP_A_LO=$(ip netns exec ns-svc-a curl -s --max-time 10 "http://127.0.0.1:8080/" 2>&1 || echo "CURL_FAILED")
echo "$RESP_A_LO"

# Test 6: Full chain from host
echo -n "  [6] host → service-a ($SVC_A_IP:8080): "
RESP_HOST=$(curl -s --max-time 10 "http://${SVC_A_IP}:8080/" 2>&1 || echo "CURL_FAILED")
echo "$RESP_HOST"

# Test 7: Cross-namespace connectivity test
echo -n "  [7] svc-b → svc-c TCP test: "
if ip netns exec ns-svc-b bash -c "echo '' > /dev/tcp/${SVC_C_IP}/8080" 2>/dev/null; then
    echo "✅ TCP connected"
else
    echo "❌ TCP connection failed"
fi

# Validate
EXPECTED="-> -> service-c"
if [[ "$RESP_A_LO" == *"service-c"* ]]; then
    echo ""
    echo "  ✅ Service chain verified! Response: $RESP_A_LO"
else
    echo ""
    echo "  ⚠️ Chain may have issues. Check diagnostics above."
    echo "     Hint: if svc-b → svc-c TCP fails, check iptables:"
    echo "     sudo iptables -L FORWARD -n -v"
fi

echo ""
echo "============================================"
echo "✅ Services are running!"
echo ""
echo "  Test from host:  curl http://${SVC_A_IP}:8080/"
echo "  Test from ns:    sudo ip netns exec ns-client curl http://${SVC_A_IP}:8080/"
echo "  Service logs:    cat /tmp/ns-svc-{a,b,c}.log"
echo ""
echo "  To stop: sudo ./cleanup.sh"
echo "============================================"

# Keep script running so background processes don't die
echo "Press Ctrl+C to stop all services..."
wait
