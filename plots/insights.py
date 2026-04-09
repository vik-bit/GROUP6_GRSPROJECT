#!/usr/bin/env python3
import numpy as np

users = [50, 100, 200, 300, 400]

# --- Hardcoded datasets including pod, node, and ping metrics ---
data_sets = {
    "Cilium": {
        "Latency": [5, 5, 5, 7, 7],
        "Bandwidth": [63434, 64087, 64964, 64604, 63203],
        "CPU_pod": [0, 0.34, 0.38, 0.44, 0.52],
        "Memory_pod": [0, 2509, 2535, 2539, 2577],
        "CPU_node": [5.45, 5.45, 6.60, 7.32, 7.49],
        "Memory_node": [20474, 20474, 20756, 21129, 21205],
        "Ping_intra": [0.075, 0.064, 0.057, 0.072, 0.057],
        "Ping_inter": [0.105, 0.097, 0.123, 0.104, 0.097]
    },
    "Calico": {
        "Latency": [5, 5, 5, 6, 7],
        "Bandwidth": [42409, 42937, 42665, 42795, 42969],
        "CPU_pod": [0.22, 0.27, 0.37, 0.42, 0.48],
        "Memory_pod": [1770, 1830, 1840, 1862, 1875],
        "CPU_node": [3.53, 3.05, 4.43, 5.66, 7.68],
        "Memory_node": [17878, 18140, 18262, 18504, 18500],
        "Ping_intra": [0.076, 0.079, 0.104, 0.072, 0.072],
        "Ping_inter": [0.163, 0.140, 0.124, 0.136, 0.173]
    },
    "Flannel": {
        "Latency": [5, 5, 5, 5, 7],
        "Bandwidth": [53834, 27352, 53407, 51343, 27827],
        "CPU_pod": [0, 0.21, 0.32, 0.32, 0.32],
        "Memory_pod": [0, 1608, 1650, 1667, 1669],
        "CPU_node": [4.58, 5.52, 5.84, 6.57, 6.57],
        "Memory_node": [20458, 20333, 20621, 20593, 20593],
        "Ping_intra": [0.080, 0.074, 0.047, 0.054, 0.069],
        "Ping_inter": [0.114, 0.131, 0.143, 0.057, 0.122]
    }
}

metrics = ["Latency", "Bandwidth", "CPU_pod", "Memory_pod", "CPU_node", "Memory_node", "Ping_intra", "Ping_inter"]
comparisons = [("Cilium", "Calico"), ("Cilium", "Flannel"), ("Calico", "Flannel")]

# --- Trend + spike detection ---
def qualitative_trend(values):
    values = np.array(values)
    diffs = np.diff(values)
    spike_threshold = 1.5 * np.mean(np.abs(diffs)) if np.mean(np.abs(diffs))>0 else 0
    spikes = [i+1 for i,d in enumerate(diffs) if abs(d) > spike_threshold]
    if all(d >= 0 for d in diffs):
        trend = "increasing steadily"
    elif all(d <= 0 for d in diffs):
        trend = "decreasing steadily"
    elif spikes:
        trend = f"mostly stable with spike(s) at user(s) {', '.join([str(users[i]) for i in spikes])}"
    else:
        trend = "fluctuates mildly"
    return trend, spikes

# --- Best/Worst detection ---
def best_worst_for_metric(metric):
    avg_vals = {cni: np.mean(data_sets[cni][metric]) for cni in data_sets}
    if metric in ["Bandwidth"]:
        best = max(avg_vals, key=avg_vals.get)
        worst = min(avg_vals, key=avg_vals.get)
    else:
        best = min(avg_vals, key=avg_vals.get)
        worst = max(avg_vals, key=avg_vals.get)
    return best, worst

# --- Generate qualitative tables ---
def generate_qualitative_tables(cni_names):
    trend_table, best_worst_table, scaling_table, tradeoff_table = [], [], [], []
    trend_table.append(["Metric"] + cni_names)
    best_worst_table.append(["Metric", "Best CNI", "Worst CNI"])
    scaling_table.append(["Metric"] + cni_names)
    tradeoff_table.append(["Metric"] + cni_names)

    for metric in metrics:
        values = {cni: np.array(data_sets[cni][metric]) for cni in cni_names}
        trend_table.append([metric] + [qualitative_trend(values[cni])[0] for cni in cni_names])
        best, worst = best_worst_for_metric(metric)
        best_worst_table.append([metric, best, worst])
        scaling_table.append([metric] + [
            "handles scaling well" if (values[cni][-1]-values[cni][0])/values[cni][0]*100 < 25
            else "scaling shows spike/drop" if values[cni][0]!=0 else "data NA"
            for cni in cni_names])
        tradeoff_table.append([metric] + [
            f"{cni} stable at low users, trend changes at high users"
            if qualitative_trend(values[cni])[0] != "increasing steadily"
            else f"{cni} behaves predictably"
            for cni in cni_names])
    return trend_table, best_worst_table, scaling_table, tradeoff_table

# --- HTML table generator with tooltips ---
def table_to_html(table, color_map=None, tooltips=None):
    html = "<table border='1' style='border-collapse: collapse;'>\n"
    for i, row in enumerate(table):
        html += "<tr>\n"
        for j, cell in enumerate(row):
            color = ""
            if color_map and (i,j) in color_map:
                color = f"background-color:{color_map[(i,j)]}"
            tooltip = ""
            if tooltips and (i,j) in tooltips:
                tooltip = f" title='{tooltips[(i,j)]}'"
            html += f"<td style='padding:5px; {color}'{tooltip}>{cell}</td>"
        html += "</tr>\n"
    html += "</table>\n<br>\n"
    return html

# --- Generate summary table with suitability ---
def generate_summary_table_with_suitability():
    summary_table = [["Metric", "Best Performer", "Most Stable", "Needs Attention", "Recommended Use Case"]]
    for metric in metrics:
        best, worst = best_worst_for_metric(metric)
        std_vals = {cni: np.std(np.array(data_sets[cni][metric])) for cni in data_sets}
        stable = min(std_vals, key=std_vals.get)

        suitability = {}
        for cni in data_sets:
            if cni == "Flannel":
                suitability[cni] = "Excellent for small cluster"
            else:  # Calico & Cilium
                suitability[cni] = "Overkill for 3-node cluster; better for production"

        summary_table.append([metric, best, stable, worst, f"{best}: {suitability[best]}"])
    return summary_table

def table_to_html_with_suitability(table):
    html = "<table border='1' style='border-collapse: collapse;'>\n"
    for i, row in enumerate(table):
        html += "<tr>\n"
        for j, cell in enumerate(row):
            color = ""
            if j == 4:
                if "Excellent" in cell:
                    color = "background-color:lightgreen"
                elif "Overkill" in cell:
                    color = "background-color:lightblue"
            html += f"<td style='padding:5px; {color}'>{cell}</td>"
        html += "</tr>\n"
    html += "</table>\n<br>\n"
    return html

# --- Assemble final HTML ---
html_content = "<html><head><title>Qualitative Observations with Nodes & Suitability</title></head><body>"
html_content += "<h1>Qualitative Observations & Tables (Including Node Metrics, Ping, and Suitability)</h1>"

for cni1, cni2 in comparisons:
    html_content += f"<h2>Comparison: {cni1} vs {cni2}</h2>"
    trend, best_worst, scaling, tradeoff = generate_qualitative_tables([cni1, cni2])
    color_map, tooltips = {}, {}

    for i,row in enumerate(trend[1:],1):
        for j,val in enumerate(row[1:],1):
            if "spike" in val or "fluctuates" in val:
                color_map[(i,j)]="yellow"
                tooltips[(i,j)]="Spike detected; check specific user loads"
            elif "increasing" in val or "decreasing" in val:
                color_map[(i,j)]="white"
    html_content += "<h3>Trend Table</h3>" + table_to_html(trend,color_map,tooltips)

    color_map = {}
    for i,row in enumerate(best_worst[1:],1):
        color_map[(i,1)]="lightgreen"
        color_map[(i,2)]="lightcoral"
    html_content += "<h3>Best/Worst Table</h3>" + table_to_html(best_worst,color_map)

    color_map = {}
    for i,row in enumerate(scaling[1:],1):
        for j,val in enumerate(row[1:],1):
            if "spike" in val: color_map[(i,j)]="yellow"
            elif "handles scaling well" in val: color_map[(i,j)]="lightgreen"
    html_content += "<h3>Scaling Impact Table</h3>" + table_to_html(scaling,color_map)

    color_map = {}
    for i,row in enumerate(tradeoff[1:],1):
        for j,val in enumerate(row[1:],1):
            if "trend changes" in val: color_map[(i,j)]="yellow"
            elif "behaves predictably" in val: color_map[(i,j)]="lightgreen"
    html_content += "<h3>Behavior/Tradeoff Table</h3>" + table_to_html(tradeoff,color_map)

# --- Add Summary Table with Suitability ---
summary_table_suit = generate_summary_table_with_suitability()
html_content += "<h2>Summary Table: All 3 CNIs with Recommended Use Case</h2>"
html_content += table_to_html_with_suitability(summary_table_suit)

html_content += "</body></html>"

with open("observations_with_nodes_and_suitability.html","w") as f:
    f.write(html_content)

print("✅ HTML saved as 'observations_with_nodes_and_suitability.html' with all metrics, ping, node usage, and suitability included.")