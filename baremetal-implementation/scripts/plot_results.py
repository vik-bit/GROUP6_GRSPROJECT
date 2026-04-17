#!/usr/bin/env python3
"""
plot_results.py — Generate comparison graphs for bare-metal CNI benchmarks.

Standalone script: reads CSV files from the results/ directory and produces
publication-quality plots. Independent of all other baremetal-implementation code.

Usage:
    python3 scripts/plot_results.py                     # plot all available CNIs
    python3 scripts/plot_results.py flannel calico       # plot specific CNIs
    python3 scripts/plot_results.py --output-dir ./figs  # custom output directory
"""

import subprocess
import sys
import os
import argparse

# ---------------------------------------------------------------------------
# 1. Auto-install dependencies
# ---------------------------------------------------------------------------
for mod in ["matplotlib", "seaborn", "numpy", "pandas"]:
    try:
        __import__(mod)
    except ImportError:
        print(f"Installing missing module: {mod}")
        subprocess.check_call([sys.executable, "-m", "pip", "install", mod])

import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import seaborn as sns
import numpy as np
import pandas as pd

# ---------------------------------------------------------------------------
# 2. Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_RESULTS_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "results")
DEFAULT_OUTPUT_DIR = os.path.join(DEFAULT_RESULTS_DIR, "plots")

CNI_COLORS = {
    "flannel": "#3498db",
    "calico":  "#e74c3c",
    "cilium":  "#2ecc71",
}
CNI_MARKERS = {"flannel": "^", "calico": "s", "cilium": "o"}

# ---------------------------------------------------------------------------
# 3. Data loading
# ---------------------------------------------------------------------------
def load_cni_data(results_dir: str, cni_names: list[str] | None = None) -> dict[str, pd.DataFrame]:
    """Load CSV files from results directory. Returns {cni_name: DataFrame}."""
    data = {}
    for fname in sorted(os.listdir(results_dir)):
        if not fname.endswith("_results.csv"):
            continue
        cni = fname.replace("_results.csv", "")
        if cni_names and cni not in cni_names:
            continue
        path = os.path.join(results_dir, fname)
        try:
            df = pd.read_csv(path)
            if len(df) == 0:
                print(f"⚠  Skipping empty file: {fname}")
                continue
            # Clean ping column (remove " ms" suffix if present)
            if "ping_intra_ms" in df.columns:
                df["ping_intra_ms"] = (
                    df["ping_intra_ms"]
                    .astype(str)
                    .str.replace(" ms", "", regex=False)
                    .astype(float)
                )
            data[cni] = df
            print(f"✅ Loaded {cni}: {len(df)} data points")
        except Exception as e:
            print(f"⚠  Error loading {fname}: {e}")
    return data

# ---------------------------------------------------------------------------
# 4. Plotting helpers
# ---------------------------------------------------------------------------
def _style():
    """Apply consistent plot style."""
    sns.set_theme(style="whitegrid", context="talk", font_scale=1.0)
    plt.rcParams.update({
        "figure.facecolor": "white",
        "axes.facecolor":   "#f8f9fa",
        "grid.alpha":       0.3,
        "axes.edgecolor":   "#cccccc",
    })


def _save(fig, output_dir, name):
    """Save figure and close."""
    os.makedirs(output_dir, exist_ok=True)
    path = os.path.join(output_dir, f"{name}.png")
    fig.savefig(path, dpi=300, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  📊 Saved {name}.png")


def _get_color(cni):
    return CNI_COLORS.get(cni, "#95a5a6")

def _get_marker(cni):
    return CNI_MARKERS.get(cni, "D")


# ---------------------------------------------------------------------------
# 5. Individual chart generators
# ---------------------------------------------------------------------------
def plot_rps(data: dict, output_dir: str):
    """Requests per second vs concurrent users."""
    fig, ax = plt.subplots(figsize=(10, 6))
    for cni, df in data.items():
        ax.plot(df["users"], df["rps"],
                marker=_get_marker(cni), color=_get_color(cni),
                label=cni.capitalize(), linewidth=2.5, markersize=8)
    ax.set_title("Requests Per Second vs Concurrent Users", fontweight="bold")
    ax.set_xlabel("Concurrent Users")
    ax.set_ylabel("RPS")
    ax.legend(framealpha=0.9)
    ax.yaxis.set_major_formatter(mticker.FormatStrFormatter("%.0f"))
    _save(fig, output_dir, "rps_comparison")


def plot_latency(data: dict, output_dir: str):
    """P95 latency vs concurrent users."""
    fig, ax = plt.subplots(figsize=(10, 6))
    for cni, df in data.items():
        ax.plot(df["users"], df["p95_latency_ms"],
                marker=_get_marker(cni), color=_get_color(cni),
                label=cni.capitalize(), linewidth=2.5, markersize=8)
    ax.set_title("95th Percentile Latency vs Concurrent Users", fontweight="bold")
    ax.set_xlabel("Concurrent Users")
    ax.set_ylabel("Latency (ms)")
    ax.legend(framealpha=0.9)
    _save(fig, output_dir, "latency_comparison")


def plot_bandwidth(data: dict, output_dir: str):
    """Bandwidth grouped bar chart."""
    fig, ax = plt.subplots(figsize=(10, 6))
    cni_names = list(data.keys())
    # Use the first CNI's user levels as reference
    users = data[cni_names[0]]["users"].tolist()
    x = np.arange(len(users))
    width = 0.8 / len(cni_names)

    for i, cni in enumerate(cni_names):
        df = data[cni]
        vals = df["bandwidth_mbps"].tolist()[:len(users)]
        offset = (i - len(cni_names) / 2 + 0.5) * width
        bars = ax.bar(x + offset, vals, width,
                      label=cni.capitalize(), color=_get_color(cni), alpha=0.85)

    ax.set_xticks(x)
    ax.set_xticklabels(users)
    ax.set_title("Network Bandwidth Comparison", fontweight="bold")
    ax.set_xlabel("Concurrent Users")
    ax.set_ylabel("Bandwidth (Mbps)")
    ax.legend(framealpha=0.9)
    ax.yaxis.set_major_formatter(mticker.FormatStrFormatter("%.0f"))
    _save(fig, output_dir, "bandwidth_comparison")


def plot_cpu(data: dict, output_dir: str):
    """CPU usage per pod vs concurrent users."""
    fig, ax = plt.subplots(figsize=(10, 6))
    for cni, df in data.items():
        ax.plot(df["users"], df["cpu_pods"],
                marker=_get_marker(cni), color=_get_color(cni),
                label=cni.capitalize(), linewidth=2.5, markersize=8)
    ax.set_title("CPU Usage per Pod vs Concurrent Users", fontweight="bold")
    ax.set_xlabel("Concurrent Users")
    ax.set_ylabel("CPU (cores)")
    ax.legend(framealpha=0.9)
    _save(fig, output_dir, "cpu_pod_comparison")


def plot_memory(data: dict, output_dir: str):
    """Memory usage per pod vs concurrent users."""
    fig, ax = plt.subplots(figsize=(10, 6))
    for cni, df in data.items():
        ax.plot(df["users"], df["memory_pods_mib"],
                marker=_get_marker(cni), color=_get_color(cni),
                label=cni.capitalize(), linewidth=2.5, markersize=8)
    ax.set_title("Memory Usage per Pod vs Concurrent Users", fontweight="bold")
    ax.set_xlabel("Concurrent Users")
    ax.set_ylabel("Memory (MiB)")
    ax.legend(framealpha=0.9)
    _save(fig, output_dir, "memory_pod_comparison")


def plot_node_cpu(data: dict, output_dir: str):
    """Node-level CPU usage vs concurrent users."""
    fig, ax = plt.subplots(figsize=(10, 6))
    for cni, df in data.items():
        ax.plot(df["users"], df["cpu_nodes_pct"],
                marker=_get_marker(cni), color=_get_color(cni),
                label=cni.capitalize(), linewidth=2.5, markersize=8)
    ax.set_title("Node CPU Usage vs Concurrent Users", fontweight="bold")
    ax.set_xlabel("Concurrent Users")
    ax.set_ylabel("CPU (%)")
    ax.legend(framealpha=0.9)
    _save(fig, output_dir, "node_cpu_comparison")


def plot_ping_box(data: dict, output_dir: str):
    """Box plot of intra-node ping latencies across load levels."""
    fig, ax = plt.subplots(figsize=(8, 5))
    ping_data = []
    labels = []
    colors = []
    for cni, df in data.items():
        ping_data.append(df["ping_intra_ms"].tolist())
        labels.append(cni.capitalize())
        colors.append(_get_color(cni))

    bp = ax.boxplot(ping_data, patch_artist=True, labels=labels)
    for patch, color in zip(bp["boxes"], colors):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)

    ax.set_title("Intra-Node Ping Latency Distribution", fontweight="bold")
    ax.set_ylabel("Ping (ms)")
    _save(fig, output_dir, "ping_intra_boxplot")


def plot_summary_table(data: dict, output_dir: str):
    """Generate a summary comparison table as an image."""
    rows = []
    for cni, df in data.items():
        rows.append({
            "CNI": cni.capitalize(),
            "Avg RPS": f"{df['rps'].mean():.1f}",
            "Max RPS": f"{df['rps'].max():.1f}",
            "Avg P95 (ms)": f"{df['p95_latency_ms'].mean():.1f}",
            "Avg BW (Mbps)": f"{df['bandwidth_mbps'].mean():.0f}",
            "Avg CPU (cores)": f"{df['cpu_pods'].mean():.4f}",
            "Avg Mem (MiB)": f"{df['memory_pods_mib'].mean():.0f}",
            "Avg Ping (ms)": f"{df['ping_intra_ms'].mean():.3f}",
        })

    summary_df = pd.DataFrame(rows)

    fig, ax = plt.subplots(figsize=(14, 1.5 + 0.5 * len(rows)))
    ax.axis("off")
    ax.set_title("CNI Performance Summary — Bare Metal", fontweight="bold",
                  fontsize=14, pad=20)

    colors_list = [[_get_color(r["CNI"].lower())] + ["#f8f9fa"] * (len(summary_df.columns) - 1)
                   for _, r in summary_df.iterrows()]

    table = ax.table(
        cellText=summary_df.values,
        colLabels=summary_df.columns,
        cellLoc="center",
        loc="center",
        cellColours=[[c if i == 0 else "#f8f9fa" for i, c in enumerate(row)]
                     for row in colors_list],
    )
    table.auto_set_font_size(False)
    table.set_fontsize(11)
    table.scale(1, 1.8)

    # Style header
    for j, col in enumerate(summary_df.columns):
        table[0, j].set_facecolor("#2c3e50")
        table[0, j].set_text_props(color="white", fontweight="bold")

    # Style CNI name column
    for i in range(len(rows)):
        table[i + 1, 0].set_text_props(color="white", fontweight="bold")

    _save(fig, output_dir, "summary_table")


# ---------------------------------------------------------------------------
# 6. Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Plot bare-metal CNI benchmark results")
    parser.add_argument("cnis", nargs="*", help="CNI names to plot (default: all available)")
    parser.add_argument("--results-dir", default=DEFAULT_RESULTS_DIR,
                        help="Directory containing *_results.csv files")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR,
                        help="Directory to save plots (default: results/plots/)")
    args = parser.parse_args()

    _style()

    # Load data
    cni_filter = args.cnis if args.cnis else None
    data = load_cni_data(args.results_dir, cni_filter)

    if not data:
        print("❌ No results CSV files found! Run experiments first:")
        print("   sudo bash scripts/run_experiment.sh flannel")
        sys.exit(1)

    print(f"\n📈 Generating plots for: {', '.join(c.capitalize() for c in data)}...\n")

    # Generate all plots
    plot_rps(data, args.output_dir)
    plot_latency(data, args.output_dir)
    plot_bandwidth(data, args.output_dir)
    plot_cpu(data, args.output_dir)
    plot_memory(data, args.output_dir)
    plot_node_cpu(data, args.output_dir)
    plot_ping_box(data, args.output_dir)
    plot_summary_table(data, args.output_dir)

    print(f"\n✅ All plots saved to: {args.output_dir}/")
    print(f"   Generated {8} charts for {len(data)} CNI(s)")


if __name__ == "__main__":
    main()
