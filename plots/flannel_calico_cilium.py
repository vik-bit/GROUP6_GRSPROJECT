#!/usr/bin/env python3

import subprocess
import sys

# ----------------------------
# 1. Ensure required modules exist
# ----------------------------
required_modules = ["matplotlib", "seaborn", "numpy"]
for module in required_modules:
    try:
        __import__(module)
    except ImportError:
        print(f"Module '{module}' not found. Installing...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", module])

# ----------------------------
# 2. Import modules
# ----------------------------
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np

# ----------------------------
# 3. Plotting function
# ----------------------------
def main():
    sns.set(style="whitegrid", context="talk")
    users = [50, 100, 200, 300, 400]

    # ---------------- Cilium ----------------
    cilium_latency = [5, 5, 5, 7, 7]
    cilium_bw = [63434, 64087, 64964, 64604, 63203]
    cilium_cpu_pod = [0, 0.34, 0.38, 0.44, 0.52]  # NA -> 0
    cilium_mem_pod = [0, 2509, 2535, 2539, 2577]
    cilium_ping_intra = [0.075, 0.064, 0.057, 0.072, 0.057]
    cilium_ping_inter = [0.105, 0.097, 0.123, 0.104, 0.097]

    # ---------------- Calico ----------------
    calico_latency = [5, 5, 5, 6, 7]
    calico_bw = [42409, 42937, 42665, 42795, 42969]
    calico_cpu_pod = [0.22, 0.27, 0.37, 0.42, 0.48]
    calico_mem_pod = [1770, 1830, 1840, 1862, 1875]
    calico_ping_intra = [0.076, 0.079, 0.104, 0.072, 0.072]
    calico_ping_inter = [0.163, 0.140, 0.124, 0.136, 0.173]

    # ---------------- Flannel ----------------
    flannel_latency = [5, 5, 5, 5, 7]
    flannel_bw = [53834, 27352, 53407, 51343, 27827]
    flannel_cpu_pod = [0, 0.21, 0.32, 0.32, 0.32]
    flannel_mem_pod = [0, 1608, 1650, 1667, 1669]
    flannel_ping_intra = [0.080, 0.074, 0.047, 0.054, 0.069]
    flannel_ping_inter = [0.114, 0.131, 0.143, 0.057, 0.122]

    # ---------------- 1. Latency Line ----------------
    plt.figure(figsize=(10,6))
    sns.lineplot(x=users, y=cilium_latency, marker='o', label='Cilium')
    sns.lineplot(x=users, y=calico_latency, marker='s', label='Calico')
    sns.lineplot(x=users, y=flannel_latency, marker='^', label='Flannel')
    plt.title("95th Percentile Latency (ms)")
    plt.xlabel("Users")
    plt.ylabel("Latency (ms)")
    plt.tight_layout()
    plt.savefig("latency_3way.png", dpi=300)
    plt.close()

    # ---------------- 2. Bandwidth Bar ----------------
    x = np.arange(len(users))
    width = 0.25
    plt.figure(figsize=(10,6))
    bars1 = plt.bar(x - width, cilium_bw, width, label='Cilium')
    bars2 = plt.bar(x, calico_bw, width, label='Calico')
    bars3 = plt.bar(x + width, flannel_bw, width, label='Flannel')
    plt.xticks(x, users)
    plt.title("Bandwidth Comparison (Mbps)")
    plt.ylabel("Mbps")
    plt.legend()
    plt.tight_layout()
    plt.savefig("bandwidth_3way.png", dpi=300)
    plt.close()

    # ---------------- 3. CPU per Pod Line ----------------
    plt.figure(figsize=(10,6))
    sns.lineplot(x=users, y=cilium_cpu_pod, marker='o', label='Cilium')
    sns.lineplot(x=users, y=calico_cpu_pod, marker='s', label='Calico')
    sns.lineplot(x=users, y=flannel_cpu_pod, marker='^', label='Flannel')
    plt.title("CPU Usage per Pod (cores)")
    plt.xlabel("Users")
    plt.ylabel("CPU")
    plt.tight_layout()
    plt.savefig("cpu_pod_3way.png", dpi=300)
    plt.close()

    # ---------------- 4. Memory per Pod Line ----------------
    plt.figure(figsize=(10,6))
    sns.lineplot(x=users, y=cilium_mem_pod, marker='o', label='Cilium')
    sns.lineplot(x=users, y=calico_mem_pod, marker='s', label='Calico')
    sns.lineplot(x=users, y=flannel_mem_pod, marker='^', label='Flannel')
    plt.title("Memory Usage per Pod (MB)")
    plt.xlabel("Users")
    plt.ylabel("Memory (MB)")
    plt.tight_layout()
    plt.savefig("mem_pod_3way.png", dpi=300)
    plt.close()

    # ---------------- 5. Ping Intra Box ----------------
    plt.figure(figsize=(8,5))
    sns.boxplot(data=[cilium_ping_intra, calico_ping_intra, flannel_ping_intra])
    plt.xticks([0,1,2], ['Cilium', 'Calico', 'Flannel'])
    plt.title("Ping Intra (ms)")
    plt.ylabel("ms")
    plt.tight_layout()
    plt.savefig("ping_intra_3way.png", dpi=300)
    plt.close()

    # ---------------- 6. Ping Inter Box ----------------
    plt.figure(figsize=(8,5))
    sns.boxplot(data=[cilium_ping_inter, calico_ping_inter, flannel_ping_inter])
    plt.xticks([0,1,2], ['Cilium', 'Calico', 'Flannel'])
    plt.title("Ping Inter (ms)")
    plt.ylabel("ms")
    plt.tight_layout()
    plt.savefig("ping_inter_3way.png", dpi=300)
    plt.close()

    print("✅ All 6 graphs for 3-way comparison generated successfully!")

# ----------------------------
if __name__ == "__main__":
    main()