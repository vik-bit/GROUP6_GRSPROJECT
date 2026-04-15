#!/bin/bash
# ============================================================================
# diagnose.sh — Comprehensive diagnostic for namespace topology issues
#
# Checks: namespaces, bridges, routing, iptables, connectivity (ICMP + TCP)
#
# Usage: sudo ./diagnose.sh
# ============================================================================

echo "============================================"
echo "🔍 Namespace Topology Diagnostics"
echo "============================================"
echo ""

# ---- Namespaces ----
echo "📌 Namespaces:"
ip netns list 2>/dev/null | while read -r ns _; do echo "  $ns"; done
echo ""

# ---- Bridges ----
echo "📌 Bridges:"
for br in br-node1 br-node2; do
    if ip link show "$br" &>/dev/null; then
        ADDR=$(ip -4 addr show "$br" 2>/dev/null | grep inet | awk '{print $2}')
        STATE=$(ip link show "$br" 2>/dev/null | grep -o 'state [A-Z]*' | awk '{print $2}')
        echo "  $br: $ADDR ($STATE)"
        # Show attached ports
        bridge link show 2>/dev/null | grep "master $br" | awk '{print "    port: "$2}' || true
    else
        echo "  $br: NOT FOUND ❌"
    fi
done
echo ""

# ---- IP Forwarding ----
echo "📌 IP Forwarding:"
FWD=$(cat /proc/sys/net/ipv4/ip_forward)
echo "  net.ipv4.ip_forward = $FWD"
[ "$FWD" = "1" ] && echo "  ✅ Enabled" || echo "  ❌ DISABLED"
echo ""

# ---- br_netfilter ----
echo "📌 Bridge netfilter:"
if [ -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
    BNF=$(cat /proc/sys/net/bridge/bridge-nf-call-iptables)
    echo "  bridge-nf-call-iptables = $BNF"
    if [ "$BNF" = "1" ]; then
        echo "  ⚠️  Bridge traffic goes through iptables FORWARD chain!"
        echo "     This can block traffic if FORWARD policy is DROP."
    fi
else
    echo "  br_netfilter module not loaded (bridge traffic bypasses iptables)"
fi
echo ""

# ---- iptables FORWARD ----
echo "📌 iptables FORWARD chain:"
echo "  Default policy: $(iptables -L FORWARD 2>/dev/null | head -1 | grep -o '(policy [A-Z]*)' || echo 'unknown')"
echo "  Rules:"
iptables -L FORWARD -n -v --line-numbers 2>/dev/null | head -20
echo ""

# ---- Namespace routes ----
echo "📌 Namespace routing tables:"
for ns in ns-svc-a ns-svc-b ns-svc-c ns-client; do
    if ip netns list 2>/dev/null | grep -q "^${ns}\b"; then
        echo "  $ns:"
        ip netns exec "$ns" ip route 2>/dev/null | sed 's/^/    /'
        ip netns exec "$ns" ip addr show 2>/dev/null | grep "inet " | sed 's/^/    /'
    fi
done
echo ""

# ---- ICMP connectivity ----
echo "📌 ICMP Connectivity:"
declare -A IPS=(["svc-a"]="10.0.1.2" ["svc-b"]="10.0.1.3" ["svc-c"]="10.0.2.2" ["client"]="10.0.1.10")

for from in svc-a svc-b client; do
    for to in svc-a svc-b svc-c; do
        if [ "$from" = "$to" ]; then continue; fi
        echo -n "  ns-$from → ${IPS[$to]} ($to): "
        if ip netns exec "ns-$from" ping -c 1 -W 2 "${IPS[$to]}" > /dev/null 2>&1; then
            echo "✅"
        else
            echo "❌ FAILED"
        fi
    done
done

# Host connectivity
echo -n "  host → 10.0.1.2 (svc-a): "
ping -c 1 -W 2 10.0.1.2 > /dev/null 2>&1 && echo "✅" || echo "❌"
echo ""

# ---- TCP connectivity (port 8080) ----
echo "📌 TCP Connectivity (port 8080):"
for ns in ns-svc-c ns-svc-b ns-svc-a; do
    IP=${IPS[${ns##ns-}]}
    echo -n "  $ns ($IP:8080): "
    if ip netns exec "$ns" bash -c "echo '' > /dev/tcp/$IP/8080" 2>/dev/null; then
        echo "✅ listening"
    elif ip netns exec "$ns" timeout 2 bash -c "echo '' > /dev/tcp/127.0.0.1/8080" 2>/dev/null; then
        echo "✅ listening (localhost only)"
    else
        echo "❌ NOT listening"
    fi
done

# Cross-namespace TCP
echo -n "  ns-svc-b → 10.0.2.2:8080 (svc-c): "
if ip netns exec ns-svc-b timeout 3 bash -c "echo '' > /dev/tcp/10.0.2.2/8080" 2>/dev/null; then
    echo "✅ connected"
else
    echo "❌ FAILED (inter-node TCP blocked)"
fi

echo -n "  ns-svc-a → 10.0.1.3:8080 (svc-b): "
if ip netns exec ns-svc-a timeout 3 bash -c "echo '' > /dev/tcp/10.0.1.3/8080" 2>/dev/null; then
    echo "✅ connected"
else
    echo "❌ FAILED (intra-node TCP blocked)"
fi
echo ""

# ---- HTTP chain test ----
echo "📌 HTTP Chain Test:"
echo -n "  service-c (loopback): "
ip netns exec ns-svc-c curl -s --max-time 3 http://127.0.0.1:8080/ 2>&1 || echo "FAILED"

echo -n "  service-b (loopback): "
ip netns exec ns-svc-b curl -s --max-time 10 http://127.0.0.1:8080/ 2>&1 || echo "FAILED"

echo -n "  service-a (loopback): "
ip netns exec ns-svc-a curl -s --max-time 15 http://127.0.0.1:8080/ 2>&1 || echo "FAILED"

echo -n "  host → svc-a: "
curl -s --max-time 15 http://10.0.1.2:8080/ 2>&1 || echo "FAILED"
echo ""

echo "============================================"
echo "🔍 Diagnostics complete"
echo ""
echo "If TCP tests fail but ICMP passes, check:"
echo "  1. Is br_netfilter loaded? (If yes, bridge traffic hits iptables)"
echo "  2. Is iptables FORWARD policy DROP?"
echo "  3. Fix: sudo sysctl net.bridge.bridge-nf-call-iptables=0"
echo "  4. Or: sudo iptables -I FORWARD -i br-node1 -j ACCEPT"
echo "============================================"
