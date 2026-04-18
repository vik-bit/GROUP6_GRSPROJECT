#!/bin/bash
# ============================================================================
# cleanup.sh — Tear down the namespace-based network topology
#
# Removes: processes, iptables rules, VXLAN, namespaces, bridges, veths
#
# Usage: sudo ./cleanup.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(realpath "$SCRIPT_DIR/..")"

echo "============================================"
echo "🧹 Cleaning up namespace topology..."
echo "============================================"

# -------------------- Step 1: Kill service processes --------------------
echo "📌 Stopping services..."

for ns in ns-client ns-svc-a ns-svc-b ns-svc-c; do
    if ip netns list 2>/dev/null | grep -q "^${ns}\b"; then
        pids=$(ip netns pids "$ns" 2>/dev/null || true)
        if [ -n "$pids" ]; then
            for pid in $pids; do
                kill -9 "$pid" 2>/dev/null || true
            done
        fi
    fi
done

# Kill any stray service binaries
pkill -9 -f "$PROJECT_ROOT/src/service" 2>/dev/null || true
sleep 1

echo "  ✅ Services stopped"

# -------------------- Step 2: Remove our iptables rules --------------------
echo "📌 Removing iptables rules..."

# Remove our bridge ACCEPT rules (try to delete specific rules we added)
iptables -D FORWARD -i br-node1 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i br-node2 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o br-node1 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -o br-node2 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -s 10.0.1.0/24 -d 10.0.2.0/24 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -s 10.0.2.0/24 -d 10.0.1.0/24 -j ACCEPT 2>/dev/null || true

# Remove calico-like rules if they were added
iptables -D FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -s 10.0.1.0/24 -d 10.0.1.0/24 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -s 10.0.2.0/24 -d 10.0.2.0/24 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -j LOG --log-prefix "NS-DROP: " --log-level 4 2>/dev/null || true
iptables -D FORWARD -j DROP 2>/dev/null || true

echo "  ✅ iptables rules cleaned"

# -------------------- Step 3: Remove VXLAN interfaces --------------------
echo "📌 Removing VXLAN interfaces..."

# Remove ip rules (vxlan mode loop-breaks)
ip rule del iif veth-tun2 table 201 2>/dev/null || true
ip rule del iif veth-tun1 table main 2>/dev/null || true
ip route flush table 201 2>/dev/null || true

# Revert the replaced node2 subnet route and the /32 gateway host route.
ip route del 10.0.2.0/24 via 192.168.100.2 dev veth-tun1 2>/dev/null || true
ip route del 10.0.2.1/32 dev br-node2 2>/dev/null || true

# Remove FORWARD rules for the veth-tun pair (vxlan mode)
iptables -D FORWARD -i veth-tun1 -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i veth-tun2 -j ACCEPT 2>/dev/null || true

# Remove VXLAN interfaces and underlay tunnel veth pair
ip link del vxlan1 2>/dev/null || true
ip link del vxlan2 2>/dev/null || true
ip link del veth-tun1 2>/dev/null || true   # removing one end deletes both

echo "  ✅ VXLAN interfaces removed"

# -------------------- Step 4: Delete namespaces --------------------
echo "📌 Deleting namespaces..."

for ns in ns-client ns-svc-a ns-svc-b ns-svc-c; do
    ip netns del "$ns" 2>/dev/null || true
done

echo "  ✅ Namespaces deleted"

# -------------------- Step 5: Remove bridges --------------------
echo "📌 Removing bridges..."

for br in br-node1 br-node2; do
    if ip link show "$br" &>/dev/null; then
        ip link set "$br" down 2>/dev/null || true
        ip link del "$br" 2>/dev/null || true
    fi
done

echo "  ✅ Bridges removed"

# -------------------- Step 6: Remove stray veth interfaces --------------------
echo "📌 Cleaning up stray veth interfaces..."

for veth in veth-client-br veth-svc-a-br veth-svc-b-br veth-svc-c-br \
            veth-client veth-svc-a veth-svc-b veth-svc-c; do
    ip link del "$veth" 2>/dev/null || true
done

echo "  ✅ Stray veths cleaned"

# -------------------- Step 7: Stop monitoring containers --------------------
echo "📌 Stopping monitoring containers..."

docker rm -f prometheus grafana 2>/dev/null || true
pkill -f node_exporter 2>/dev/null || true
pkill -f process-exporter 2>/dev/null || true

echo "  ✅ Monitoring stopped"

# -------------------- Step 8: Clean temp files --------------------
rm -f /tmp/ns-svc-a.log /tmp/ns-svc-b.log /tmp/ns-svc-c.log /tmp/ns-service-pids 2>/dev/null || true

echo ""
echo "============================================"
echo "✅ Cleanup complete!"
echo "============================================"
