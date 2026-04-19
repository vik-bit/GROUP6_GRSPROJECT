#!/bin/bash
# ============================================================================
# setup_topology.sh — Create Linux namespace-based network topology
#
# Replicates a 2-node Kubernetes cluster using:
#   - 4 network namespaces (client, svc-a, svc-b, svc-c)
#   - 2 Linux bridges (br-node1, br-node2) simulating nodes
#   - veth pairs connecting namespaces to bridges
#   - Static routing or VXLAN/iptables extensions
#
# Modes:
#   bridge   — baseline: bridges + static routing (default)
#   vxlan    — VXLAN overlay between bridges (Flannel-like)
#   iptables — iptables FORWARD chain rules (Calico-like)
#
# Usage: sudo ./setup_topology.sh [--mode bridge|vxlan|iptables]
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -------------------- Configuration --------------------
MODE="bridge"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        bridge|vxlan|iptables) MODE="$1"; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Subnet configuration
NODE1_SUBNET="10.0.1.0/24"
NODE1_GW="10.0.1.1"
NODE2_SUBNET="10.0.2.0/24"
NODE2_GW="10.0.2.1"

# Namespace IPs
CLIENT_IP="10.0.1.10"
SVC_A_IP="10.0.1.2"
SVC_B_IP="10.0.1.3"
SVC_C_IP="10.0.2.2"

# VXLAN config
VXLAN_ID=42
VXLAN_PORT=4789

echo "============================================"
echo "🌐 Setting up namespace topology (mode: $MODE)"
echo "============================================"

# -------------------- Step 0: Clean previous state --------------------
echo "📌 Cleaning up any previous topology..."
"$SCRIPT_DIR/cleanup.sh" 2>/dev/null || true
echo ""

# -------------------- Step 1: Enable IP forwarding --------------------
echo "📌 Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# -------------------- Step 2: Create bridges --------------------
echo "📌 Creating bridges..."

ip link add br-node1 type bridge
ip addr add "$NODE1_GW/24" dev br-node1
ip link set br-node1 up

ip link add br-node2 type bridge
ip addr add "$NODE2_GW/24" dev br-node2
ip link set br-node2 up

echo "  ✅ br-node1 ($NODE1_GW) and br-node2 ($NODE2_GW) created"

# -------------------- Step 3: Create namespaces --------------------
echo "📌 Creating namespaces..."

for ns in ns-client ns-svc-a ns-svc-b ns-svc-c; do
    ip netns add "$ns"
    ip netns exec "$ns" ip link set lo up
done

echo "  ✅ Namespaces created: ns-client, ns-svc-a, ns-svc-b, ns-svc-c"

# -------------------- Step 4: Create veth pairs and connect --------------------
echo "📌 Creating veth pairs and attaching to bridges..."

create_veth_pair() {
    local ns=$1
    local ip=$2
    local bridge=$3
    local gw=$4
    local veth_ns="veth-${ns##ns-}"
    local veth_br="veth-${ns##ns-}-br"

    # Create veth pair
    ip link add "$veth_ns" type veth peer name "$veth_br"

    # Move one end into namespace
    ip link set "$veth_ns" netns "$ns"

    # Configure namespace side
    ip netns exec "$ns" ip addr add "${ip}/24" dev "$veth_ns"
    ip netns exec "$ns" ip link set "$veth_ns" up
    ip netns exec "$ns" ip route add default via "$gw"

    # Attach bridge side
    ip link set "$veth_br" master "$bridge"
    ip link set "$veth_br" up

    echo "  ✅ $ns ($ip) ↔ $bridge via $veth_ns/$veth_br"
}

# Node1 namespaces
create_veth_pair "ns-client" "$CLIENT_IP" "br-node1" "$NODE1_GW"
create_veth_pair "ns-svc-a"  "$SVC_A_IP"  "br-node1" "$NODE1_GW"
create_veth_pair "ns-svc-b"  "$SVC_B_IP"  "br-node1" "$NODE1_GW"

# Node2 namespaces
create_veth_pair "ns-svc-c"  "$SVC_C_IP"  "br-node2" "$NODE2_GW"

# -------------------- Step 5: Ensure iptables allows bridge traffic --------------------
echo "📌 Configuring iptables for bridge traffic..."

# Docker sets FORWARD policy to DROP. We need explicit ACCEPT rules for our bridges.
# These are inserted at the TOP of FORWARD chain so they take priority.
iptables -I FORWARD 1 -i br-node1 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 2 -i br-node2 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 3 -o br-node1 -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 4 -o br-node2 -j ACCEPT 2>/dev/null || true

# Also allow traffic between bridge subnets routed through host
iptables -I FORWARD 5 -s "$NODE1_SUBNET" -d "$NODE2_SUBNET" -j ACCEPT 2>/dev/null || true
iptables -I FORWARD 6 -s "$NODE2_SUBNET" -d "$NODE1_SUBNET" -j ACCEPT 2>/dev/null || true

echo "  ✅ iptables FORWARD rules added for bridge traffic"

# -------------------- Step 6: Mode-specific configuration --------------------

case "$MODE" in
    vxlan)
        echo "📌 Setting up VXLAN overlay (Flannel-like)..."

        # Underlay veth pair — simulates the extra inter-node hop a VXLAN CNI adds.
        ip link add veth-tun1 type veth peer name veth-tun2
        ip addr add 192.168.100.1/30 dev veth-tun1
        ip addr add 192.168.100.2/30 dev veth-tun2
        ip link set veth-tun1 up
        ip link set veth-tun2 up

        # Standalone VXLAN objects (different VNIs to coexist on same host).
        ip link add vxlan1 type vxlan id $VXLAN_ID     local 192.168.100.1 dstport $VXLAN_PORT nolearning
        ip link set vxlan1 up
        ip link add vxlan2 type vxlan id $((VXLAN_ID+1)) local 192.168.100.2 dstport $VXLAN_PORT nolearning
        ip link set vxlan2 up

        # Keep the br-node2 gateway IP reachable directly (needed for ARP/binds).
        ip route add "$NODE2_GW/32" dev br-node2 2>/dev/null || true

        # Redirect all traffic destined for node2's subnet through the veth-tun pair.
        # This simulates the extra encapsulation hop that Flannel/VXLAN CNI adds.
        # We only redirect TO node2; traffic TO node1 stays direct (via br-node1).
        ip route replace "$NODE2_SUBNET" via 192.168.100.2 dev veth-tun1

        # Loop-break: after a packet crosses veth-tun1→veth-tun2, deliver it directly
        # to br-node2 using table 201 (which has the connected route dev br-node2).
        # Must NOT use "table main" here — main now has the veth-tun1 route which loops.
        ip route add "$NODE2_SUBNET" dev br-node2 table 201
        ip rule add iif veth-tun2 table 201 priority 41

        # Safety loop-break for veth-tun1 (in case of edge-case return traffic).
        # Node1 subnet is still in main as the direct connected route so this is safe.
        ip rule add iif veth-tun1 table main priority 40

        # Allow forwarding through the underlay veth pair.
        iptables -I FORWARD 1 -i veth-tun1 -j ACCEPT 2>/dev/null || true
        iptables -I FORWARD 1 -i veth-tun2 -j ACCEPT 2>/dev/null || true

        echo "  ✅ VXLAN overlay configured (VNI=$VXLAN_ID)"
        echo "     Underlay:  192.168.100.1 (veth-tun1) ↔ 192.168.100.2 (veth-tun2)"
        echo "     Objects:   vxlan1 (VNI=$VXLAN_ID) + vxlan2 (VNI=$((VXLAN_ID+1))) loaded"
        ;;

    iptables)
        echo "📌 Setting up iptables rules (Calico-like)..."

        # Add Calico-like policy rules AFTER the bridge ACCEPT rules
        iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A FORWARD -s $NODE1_SUBNET -d $NODE1_SUBNET -j ACCEPT
        iptables -A FORWARD -s $NODE2_SUBNET -d $NODE2_SUBNET -j ACCEPT
        iptables -A FORWARD -s $NODE1_SUBNET -d $NODE2_SUBNET -j ACCEPT
        iptables -A FORWARD -s $NODE2_SUBNET -d $NODE1_SUBNET -j ACCEPT
        iptables -A FORWARD -j LOG --log-prefix "NS-DROP: " --log-level 4
        iptables -A FORWARD -j DROP

        echo "  ✅ iptables Calico-like rules configured"
        echo "     Check logs: dmesg | grep 'NS-DROP'"
        ;;

    bridge)
        echo "  ✅ Baseline bridge+routing mode (no extra config needed)"
        ;;

    *)
        echo "❌ Unknown mode: $MODE"
        echo "   Supported modes: bridge, vxlan, iptables"
        exit 1
        ;;
esac

# -------------------- Step 7: Verify connectivity --------------------
echo ""
echo "📌 Verifying connectivity..."

verify_ping() {
    local from_ns=$1
    local dest=$2
    local label=$3
    echo -n "  $label: "
    if ip netns exec "$from_ns" ping -c 1 -W 2 "$dest" > /dev/null 2>&1; then
        echo "✅"
    else
        echo "❌ (FAILED: $from_ns → $dest)"
    fi
}

verify_ping "ns-client" "$SVC_A_IP"  "client → svc-a"
verify_ping "ns-client" "$SVC_B_IP"  "client → svc-b"
verify_ping "ns-svc-a"  "$SVC_B_IP"  "svc-a → svc-b (intra-node)"
verify_ping "ns-svc-a"  "$SVC_C_IP"  "svc-a → svc-c (inter-node)"
verify_ping "ns-svc-b"  "$SVC_C_IP"  "svc-b → svc-c (inter-node)"

# Also verify host → namespace connectivity
echo -n "  host → svc-a: "
if ping -c 1 -W 2 "$SVC_A_IP" > /dev/null 2>&1; then
    echo "✅"
else
    echo "❌"
fi

echo ""
echo "============================================"
echo "✅ Topology setup complete (mode: $MODE)"
echo ""
echo "  Namespace IPs:"
echo "    ns-client  = $CLIENT_IP"
echo "    ns-svc-a   = $SVC_A_IP"
echo "    ns-svc-b   = $SVC_B_IP"
echo "    ns-svc-c   = $SVC_C_IP"
echo ""
echo "  Bridges:"
echo "    br-node1   = $NODE1_GW ($NODE1_SUBNET)"
echo "    br-node2   = $NODE2_GW ($NODE2_SUBNET)"
echo "============================================"
