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
# 2. Import modules after installation
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

    # --- Calico ---
    calico_latency = [5, 5, 5, 6, 7]
    calico_bw = [42409, 42937, 42665, 42795, 42969]
    calico_cpu_pod = [0.22, 0.27, 0.37, 0.42, 0.48]
    calico_mem_pod = [1770, 1830, 1840, 1862, 1875]
    calico_cpu_node = [3.53, 3.05, 4.43, 5.66, 7.68]
    calico_mem_node = [17878, 18140, 18262, 18504, 18500]
    calico_ping_intra = [0.076, 0.079, 0.104, 0.072, 0.072]
    calico_ping_inter = [0.163, 0.140, 0.124, 0.136, 0.173]

    # --- Flannel ---
    flannel_latency = [5, 5, 5, 5, 7]
    flannel_bw = [53834, 27352, 53407, 51343, 27827]
    flannel_cpu_pod = [0.0, 0.21, 0.32, 0.32, 0.32]  # NA treated as 0
    flannel_mem_pod = [0, 1608, 1650, 1667, 1669]
    flannel_cpu_node = [0.0, 4.58, 5.52, 5.84, 6.57]
    flannel_mem_node = [0.0, 20458, 20333, 20621, 20593]
    flannel_ping_intra = [0.080, 0.074, 0.047, 0.054, 0.069]
    flannel_ping_inter = [0.114, 0.131, 0.143, 0.057, 0.122]

    # ------------------ 1. Latency Line ------------------
    plt.figure(figsize=(10,6))
    sns.lineplot(x=users, y=calico_latency, marker='o', label='Calico')
    sns.lineplot(x=users, y=flannel_latency, marker='s', label='Flannel')
    for x,y in zip(users, calico_latency):
        plt.text(x, y+0.1, f"{y}", ha='center')
    plt.title("95th Percentile Latency (ms)")
    plt.xlabel("Users")
    plt.ylabel("Latency (ms)")
    plt.tight_layout()
    plt.savefig("calico_flannel_latency.png", dpi=300)
    plt.close()

    # ------------------ 2. Bandwidth Bar ------------------
    x = np.arange(len(users))
    width = 0.35
    plt.figure(figsize=(10,6))
    bars1 = plt.bar(x - width/2, calico_bw, width, label='Calico')
    bars2 = plt.bar(x + width/2, flannel_bw, width, label='Flannel')
    for bars in [bars1, bars2]:
        for b in bars:
            plt.text(b.get_x()+b.get_width()/2, b.get_height(), f"{int(b.get_height())}", ha='center', va='bottom', fontsize=8)
    plt.xticks(x, users)
    plt.title("Bandwidth Comparison (Mbps)")
    plt.xlabel("Users")
    plt.ylabel("Mbps")
    plt.legend()
    plt.tight_layout()
    plt.savefig("calico_flannel_bandwidth.png", dpi=300)
    plt.close()

    # ------------------ 3. CPU per Pod Line ------------------
    plt.figure(figsize=(10,6))
    sns.lineplot(x=users, y=calico_cpu_pod, marker='o', label='Calico')
    sns.lineplot(x=users, y=flannel_cpu_pod, marker='s', label='Flannel')
    plt.title("CPU Usage per Pod")
    plt.xlabel("Users")
    plt.ylabel("CPU (cores)")
    plt.tight_layout()
    plt.savefig("calico_flannel_cpu_pod.png", dpi=300)
    plt.close()

    # ------------------ 4. Memory per Pod Line ------------------
    plt.figure(figsize=(10,6))
    sns.lineplot(x=users, y=calico_mem_pod, marker='o', label='Calico')
    sns.lineplot(x=users, y=flannel_mem_pod, marker='s', label='Flannel')
    plt.title("Memory Usage per Pod (MB)")
    plt.xlabel("Users")
    plt.ylabel("Memory (MB)")
    plt.tight_layout()
    plt.savefig("calico_flannel_mem_pod.png", dpi=300)
    plt.close()

    # ------------------ 5. Ping Intra Box ------------------
    plt.figure(figsize=(8,5))
    sns.boxplot(data=[calico_ping_intra, flannel_ping_intra])
    plt.xticks([0,1], ['Calico', 'Flannel'])
    plt.title("Ping Intra (ms)")
    plt.ylabel("ms")
    plt.tight_layout()
    plt.savefig("calico_flannel_ping_intra.png", dpi=300)
    plt.close()

    # ------------------ 6. Ping Inter Box ------------------
    plt.figure(figsize=(8,5))
    sns.boxplot(data=[calico_ping_inter, flannel_ping_inter])
    plt.xticks([0,1], ['Calico', 'Flannel'])
    plt.title("Ping Inter (ms)")
    plt.ylabel("ms")
    plt.tight_layout()
    plt.savefig("calico_flannel_ping_inter.png", dpi=300)
    plt.close()

    print("✅ All 6 graphs generated successfully in current folder!")

# ----------------------------
# Run
# ----------------------------
if __name__ == "__main__":
    main()