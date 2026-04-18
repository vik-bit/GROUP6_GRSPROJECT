#!/usr/bin/env python3
"""
generate_plots.py — Namespace Implementation Benchmark Plots
Reads the 3 result CSVs (bridge, vxlan, iptables) and produces 6 charts
that mirror the style of the Kind implementation plots in ../plots/.

Usage:
    python3 generate_plots.py
Output PNGs are written to the same directory as this script.
"""

import subprocess, sys

# ── auto-install missing deps (same pattern as Kind scripts) ─────────────────
for module in ["matplotlib", "seaborn", "numpy", "pandas"]:
    try:
        __import__(module)
    except ImportError:
        print(f"Installing '{module}'…")
        subprocess.check_call([sys.executable, "-m", "pip", "install", module])

import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import seaborn as sns
import numpy as np
from pathlib import Path

# ── paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR  = Path(__file__).parent
RESULTS_DIR = SCRIPT_DIR.parent / "results"
OUT_DIR     = SCRIPT_DIR          # plots land next to this script

# ── load CSVs ─────────────────────────────────────────────────────────────────
def load(mode: str) -> pd.DataFrame:
    path = RESULTS_DIR / f"namespace_{mode}_results.csv"
    df = pd.read_csv(path).dropna()
    df["users"] = df["users"].astype(int)
    return df.sort_values("users").reset_index(drop=True)

bridge   = load("bridge")
vxlan    = load("vxlan")
iptables = load("iptables")

users = bridge["users"].tolist()        # [50, 100, 200, 300, 400]

# ── helpers ───────────────────────────────────────────────────────────────────
PALETTE = {
    "Bridge":   "#4C72B0",   # seaborn blue
    "VXLAN":    "#DD8452",   # seaborn orange
    "iptables": "#55A868",   # seaborn green
}
MARKERS = {"Bridge": "o", "VXLAN": "s", "iptables": "^"}

def col(df, name):
    return df[name].tolist()

def save(name):
    plt.tight_layout()
    plt.savefig(OUT_DIR / name, dpi=300)
    plt.close()
    print(f"  ✅  {name}")

sns.set(style="whitegrid", context="talk")

# ── 1. 95th-Percentile Latency — line chart ───────────────────────────────────
plt.figure(figsize=(10, 6))
for label, df in [("Bridge", bridge), ("VXLAN", vxlan), ("iptables", iptables)]:
    y = col(df, "p95_latency_ms")
    sns.lineplot(x=users, y=y, marker=MARKERS[label],
                 label=label, color=PALETTE[label])
    for xi, yi in zip(users, y):
        plt.text(xi, yi + 0.05, f"{yi:.1f}", ha="center", fontsize=9)

plt.title("95th Percentile Latency — Namespace Implementation")
plt.xlabel("Concurrent Users")
plt.ylabel("Latency (ms)")
plt.legend()
save("latency_3way.png")

# ── 2. Throughput (RPS) — line chart ─────────────────────────────────────────
plt.figure(figsize=(10, 6))
for label, df in [("Bridge", bridge), ("VXLAN", vxlan), ("iptables", iptables)]:
    y = col(df, "rps")
    sns.lineplot(x=users, y=y, marker=MARKERS[label],
                 label=label, color=PALETTE[label])

plt.title("Request Throughput (RPS) — Namespace Implementation")
plt.xlabel("Concurrent Users")
plt.ylabel("Requests / sec")
plt.legend()
save("rps_3way.png")

# ── 3. Bandwidth — grouped bar chart ─────────────────────────────────────────
x     = np.arange(len(users))
width = 0.25
fig, ax = plt.subplots(figsize=(10, 6))
for i, (label, df) in enumerate([("Bridge", bridge), ("VXLAN", vxlan), ("iptables", iptables)]):
    vals = col(df, "bandwidth_mbps")
    bars = ax.bar(x + (i - 1) * width, vals, width,
                  label=label, color=PALETTE[label])
    for b in bars:
        ax.text(b.get_x() + b.get_width() / 2, b.get_height(),
                f"{int(b.get_height()):,}", ha="center", va="bottom", fontsize=8)

ax.set_xticks(x)
ax.set_xticklabels(users)
ax.set_title("Bandwidth Comparison (Mbps) — Namespace Implementation")
ax.set_xlabel("Concurrent Users")
ax.set_ylabel("Mbps")
ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda v, _: f"{int(v):,}"))
ax.legend()
save("bandwidth_3way.png")

# ── 4. CPU per Pod — line chart ───────────────────────────────────────────────
plt.figure(figsize=(10, 6))
for label, df in [("Bridge", bridge), ("VXLAN", vxlan), ("iptables", iptables)]:
    sns.lineplot(x=users, y=col(df, "cpu_pods"), marker=MARKERS[label],
                 label=label, color=PALETTE[label])

plt.title("CPU Usage per Pod — Namespace Implementation")
plt.xlabel("Concurrent Users")
plt.ylabel("CPU (cores)")
plt.legend()
save("cpu_pod_3way.png")

# ── 5. Memory per Pod — line chart ───────────────────────────────────────────
plt.figure(figsize=(10, 6))
for label, df in [("Bridge", bridge), ("VXLAN", vxlan), ("iptables", iptables)]:
    sns.lineplot(x=users, y=col(df, "memory_pods"), marker=MARKERS[label],
                 label=label, color=PALETTE[label])

plt.title("Memory Usage per Pod (MB) — Namespace Implementation")
plt.xlabel("Concurrent Users")
plt.ylabel("Memory (MB)")
plt.legend()
save("mem_pod_3way.png")

# ── 6. Ping Intra-node — box chart ───────────────────────────────────────────
plt.figure(figsize=(8, 5))
data_intra  = [col(bridge, "ping_intra_ms"), col(vxlan, "ping_intra_ms"), col(iptables, "ping_intra_ms")]
labels_all  = ["Bridge", "VXLAN", "iptables"]
colors_all  = [PALETTE[l] for l in labels_all]
bp = sns.boxplot(data=data_intra, palette=colors_all)
bp.set_xticks([0, 1, 2])
bp.set_xticklabels(labels_all)
plt.title("Ping Intra-node (ms) — Namespace Implementation")
plt.ylabel("ms")
save("ping_intra_3way.png")

# ── 7. Ping Inter-node — box chart ───────────────────────────────────────────
plt.figure(figsize=(8, 5))
data_inter = [col(bridge, "ping_inter_ms"), col(vxlan, "ping_inter_ms"), col(iptables, "ping_inter_ms")]
bp = sns.boxplot(data=data_inter, palette=colors_all)
bp.set_xticks([0, 1, 2])
bp.set_xticklabels(labels_all)
plt.title("Ping Inter-node (ms) — Namespace Implementation")
plt.ylabel("ms")
save("ping_inter_3way.png")

print("\n✅ All 7 plots saved to:", OUT_DIR)
