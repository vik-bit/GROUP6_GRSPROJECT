#!/usr/bin/env python3

import subprocess
import sys

# ----------------------------
# Ensure required modules
# ----------------------------
required_modules = ["matplotlib", "seaborn", "numpy"]
for module in required_modules:
    try:
        __import__(module)
    except ImportError:
        print(f"Module '{module}' not found. Installing...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", module])

import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np

def main():
    sns.set(style="whitegrid", context="talk")
    
    users = [50, 100, 200, 300, 400]

    # --- Cilium ---
    cilium_latency = [5, 5, 5, 7, 7]
    cilium_bw = [63434, 64087, 64964, 64604, 63203]
    cilium_cpu_pod = [None, 0.34, 0.38, 0.44, 0.52]  # NA treated as None
    cilium_mem_pod = [None, 2509, 2535, 2539, 2577]
    cilium_cpu_node = [None, 5.45, 6.60, 7.32, 7.49]
    cilium_mem_node = [None, 20474, 20756, 21129, 21205]
    cilium_ping_intra = [0.075, 0.064, 0.057, 0.072, 0.057]
    cilium_ping_inter = [0.105, 0.097, 0.123, 0.104, 0.097]

    # --- Calico ---
    calico_latency = [5, 5, 5, 6, 7]
    calico_bw = [42409, 42937, 42665, 42795, 42969]
    calico_cpu_pod = [0.22, 0.27, 0.37, 0.42, 0.48]
    calico_mem_pod = [1770, 1830, 1840, 1862, 1875]
    calico_cpu_node = [3.53, 3.05, 4.43, 5.66, 7.68]
    calico_mem_node = [17878, 18140, 18262, 18504, 18500]
    calico_ping_intra = [0.076, 0.079, 0.104, 0.072, 0.072]
    calico_ping_inter = [0.163, 0.140, 0.124, 0.136, 0.173]

    # ------------------ 1. Latency Line ------------------
    plt.figure(figsize=(10,6))
    sns.lineplot(x=users, y=cilium_latency, marker='o', label='Cilium')
    sns.lineplot(x=users, y=calico_latency, marker='s', label='Calico')
    plt.title("95th Percentile Latency (ms)")
    plt.xlabel("Users")
    plt.ylabel("Latency (ms)")
    plt.tight_layout()
    plt.savefig("cilium_calico_latency.png", dpi=300)
    plt.close()

    # ------------------ 2. Bandwidth Bar ------------------
    x = np.arange(len(users))
    width = 0.35
    plt.figure(figsize=(10,6))
    bars1 = plt.bar(x - width/2, cilium_bw, width, label='Cilium')
    bars2 = plt.bar(x + width/2, calico_bw, width, label='Calico')
    plt.xticks(x, users)
    plt.title("Bandwidth Comparison (Mbps)")
    plt.ylabel("Mbps")
    plt.legend()
    plt.tight_layout()
    plt.savefig("cilium_calico_bandwidth.png", dpi=300)
    plt.close()

    # ------------------ 3. CPU per Pod Line ------------------
    plt.figure(figsize=(10,6))
    sns.lineplot(x=users, y=[v or 0 for v in cilium_cpu_pod], marker='o', label='Cilium')
    sns.lineplot(x=users, y=calico_cpu_pod, marker='s', label='Calico')
    plt.title("CPU Usage per Pod")
    plt.xlabel("Users")
    plt.ylabel("CPU (cores)")
    plt.tight_layout()
    plt.savefig("cilium_calico_cpu_pod.png", dpi=300)
    plt.close()

    # ------------------ 4. Memory per Pod Line ------------------
    plt.figure(figsize=(10,6))
    sns.lineplot(x=users, y=[v or 0 for v in cilium_mem_pod], marker='o', label='Cilium')
    sns.lineplot(x=users, y=calico_mem_pod, marker='s', label='Calico')
    plt.title("Memory Usage per Pod (MB)")
    plt.xlabel("Users")
    plt.ylabel("Memory (MB)")
    plt.tight_layout()
    plt.savefig("cilium_calico_mem_pod.png", dpi=300)
    plt.close()

    # ------------------ 5. Ping Intra Box ------------------
    plt.figure(figsize=(8,5))
    sns.boxplot(data=[cilium_ping_intra, calico_ping_intra])
    plt.xticks([0,1], ['Cilium', 'Calico'])
    plt.title("Ping Intra (ms)")
    plt.ylabel("ms")
    plt.tight_layout()
    plt.savefig("cilium_calico_ping_intra.png", dpi=300)
    plt.close()

    # ------------------ 6. Ping Inter Box ------------------
    plt.figure(figsize=(8,5))
    sns.boxplot(data=[cilium_ping_inter, calico_ping_inter])
    plt.xticks([0,1], ['Cilium', 'Calico'])
    plt.title("Ping Inter (ms)")
    plt.ylabel("ms")
    plt.tight_layout()
    plt.savefig("cilium_calico_ping_inter.png", dpi=300)
    plt.close()

    print("✅ All 6 graphs for Cilium vs Calico generated successfully!")

if __name__ == "__main__":
    main()