#!/usr/bin/env python3
"""
plot_summary_table.py — Namespace Implementation Performance Summary Table

Mirrors the plot_summary_table() function in:
  baremetal-implementation/scripts/plot_results.py

Reads the 3 namespace result CSVs (bridge, vxlan, iptables) from the results/
directory and saves a publication-quality summary table PNG to this plots/
directory.

Usage:
    python3 plots/plot_summary_table.py
    python3 plots/plot_summary_table.py --output-dir /some/other/dir
"""

import subprocess
import sys
import os
import argparse

# ---------------------------------------------------------------------------
# 1. Auto-install dependencies (same pattern as baremetal plot_results.py)
# ---------------------------------------------------------------------------
for mod in ["matplotlib", "seaborn", "numpy", "pandas"]:
    try:
        __import__(mod)
    except ImportError:
        print(f"Installing missing module: {mod}")
        subprocess.check_call([sys.executable, "-m", "pip", "install", mod])

import matplotlib.pyplot as plt
import seaborn as sns
import pandas as pd

# ---------------------------------------------------------------------------
# 2. Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
RESULTS_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "results")
OUTPUT_DIR  = SCRIPT_DIR   # default: plots land next to this script

# Colour palette mirrors the namespace generate_plots.py colours
MODE_COLORS = {
    "bridge":   "#4C72B0",
    "vxlan":    "#DD8452",
    "iptables": "#55A868",
}

# Friendly display name
MODE_LABELS = {
    "bridge":   "Bridge",
    "vxlan":    "VXLAN",
    "iptables": "iptables",
}

# ---------------------------------------------------------------------------
# 3. Data loading
# ---------------------------------------------------------------------------
def load_data(results_dir: str) -> dict:
    """Load all namespace_*_results.csv files. Returns {mode: DataFrame}."""
    data = {}
    for fname in sorted(os.listdir(results_dir)):
        if not fname.startswith("namespace_") or not fname.endswith("_results.csv"):
            continue
        mode = fname.replace("namespace_", "").replace("_results.csv", "")
        path = os.path.join(results_dir, fname)
        try:
            df = pd.read_csv(path).dropna()
            if len(df) == 0:
                print(f"⚠  Skipping empty file: {fname}")
                continue
            data[mode] = df
            print(f"✅ Loaded {mode}: {len(df)} rows")
        except Exception as exc:
            print(f"⚠  Error loading {fname}: {exc}")
    return data


# ---------------------------------------------------------------------------
# 4. Summary table (mirrors baremetal plot_summary_table)
# ---------------------------------------------------------------------------
def plot_summary_table(data: dict, output_dir: str):
    """Generate a summary comparison table as a PNG image."""

    rows = []
    for mode, df in data.items():
        label = MODE_LABELS.get(mode, mode.capitalize())

        # namespace CSVs use 'memory_pods' (MB) rather than 'memory_pods_mib'
        mem_col = "memory_pods" if "memory_pods" in df.columns else "memory_pods_mib"

        # ping_inter_ms is present in namespace CSVs; keep it as extra info
        has_inter = "ping_inter_ms" in df.columns

        rows.append({
            "Mode":           label,
            "Avg RPS":        f"{df['rps'].mean():.1f}",
            "Max RPS":        f"{df['rps'].max():.1f}",
            "P95 Lat (ms)":   f"{df['p95_latency_ms'].mean():.1f}",
            "BW (Mbps)":      f"{df['bandwidth_mbps'].mean():.0f}",
            "CPU (cores)":    f"{df['cpu_pods'].mean():.4f}",
            "Mem (MB)":       f"{df[mem_col].mean():.0f}",
            "Ping Intra (ms)":f"{df['ping_intra_ms'].mean():.3f}",
            "Ping Inter (ms)":f"{df['ping_inter_ms'].mean():.3f}" if has_inter else "N/A",
        })

    summary_df = pd.DataFrame(rows)
    n_rows = len(rows)
    n_cols = len(summary_df.columns)

    # Apply consistent style (same as baremetal)
    sns.set_theme(style="whitegrid", context="talk", font_scale=1.0)
    plt.rcParams.update({
        "figure.facecolor": "white",
        "axes.facecolor":   "#f8f9fa",
    })

    fig, ax = plt.subplots(figsize=(18, 1.5 + 0.6 * n_rows))
    ax.axis("off")
    ax.set_title(
        "CNI Performance Summary — Namespace (Baseline) Implementation",
        fontweight="bold", fontsize=14, pad=20,
    )

    # Build per-cell colours: mode column gets the mode colour, rest light grey
    cell_colours = []
    for _, row in summary_df.iterrows():
        mode_key = {v: k for k, v in MODE_LABELS.items()}.get(row["Mode"], row["Mode"].lower())
        row_color = MODE_COLORS.get(mode_key, "#95a5a6")
        cell_colours.append(
            [row_color if j == 0 else "#f8f9fa" for j in range(n_cols)]
        )

    table = ax.table(
        cellText=summary_df.values,
        colLabels=summary_df.columns,
        cellLoc="center",
        loc="center",
        cellColours=cell_colours,
    )
    table.auto_set_font_size(False)
    table.set_fontsize(10)
    table.auto_set_column_width(col=list(range(n_cols)))
    table.scale(1, 1.8)

    # Dark header row (identical to baremetal style)
    for j in range(n_cols):
        table[0, j].set_facecolor("#2c3e50")
        table[0, j].set_text_props(color="white", fontweight="bold")

    # White bold text for the Mode name column
    for i in range(n_rows):
        table[i + 1, 0].set_text_props(color="white", fontweight="bold")

    os.makedirs(output_dir, exist_ok=True)
    out_path = os.path.join(output_dir, "summary_table.png")
    fig.savefig(out_path, dpi=300, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"\n  📊 Saved summary_table.png → {out_path}")


# ---------------------------------------------------------------------------
# 5. Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Generate performance summary table for namespace benchmarks"
    )
    parser.add_argument(
        "--results-dir", default=RESULTS_DIR,
        help="Directory containing namespace_*_results.csv files",
    )
    parser.add_argument(
        "--output-dir", default=OUTPUT_DIR,
        help="Directory to save the table PNG (default: plots/)",
    )
    args = parser.parse_args()

    data = load_data(args.results_dir)
    if not data:
        print("❌ No namespace_*_results.csv files found in:", args.results_dir)
        sys.exit(1)

    print(f"\n📋 Generating summary table for: {', '.join(MODE_LABELS.get(m, m) for m in data)}...\n")
    plot_summary_table(data, args.output_dir)
    print("\n✅ Done.")


if __name__ == "__main__":
    main()
