"""
Plotting helper for VM Locust CSV results.

Usage:
  python plot_results_vm.py [base]

Default base: locust_stats (reads CSVs from ../load-test/)
Outputs PNGs into the `plots/` folder next to this script.
"""

import os
import sys
import pandas as pd
import matplotlib.pyplot as plt


def find_history_csv(load_test_dir, base):
    # prefer files containing 'history'
    for f in os.listdir(load_test_dir):
        if f.endswith('.csv') and base in f and 'history' in f:
            return os.path.join(load_test_dir, f)

    # fallback: any CSV containing the base
    for f in os.listdir(load_test_dir):
        if f.endswith('.csv') and base in f:
            return os.path.join(load_test_dir, f)

    return None


def detect_columns(df):
    cols = {c.lower(): c for c in df.columns}
    # timestamp
    ts = None
    for name in ('timestamp', 'time', 'date'):
        if name in cols:
            ts = cols[name]
            break

    # average response
    avg = None
    for name in ('average response time', 'average_response_time', 'avg_response_time', 'average'):
        if name in cols:
            avg = cols[name]
            break
    if not avg:
        for c in df.columns:
            if 'average' in c.lower() and 'response' in c.lower():
                avg = c
                break

    # requests per second
    rps = None
    for name in ('requests/s', 'requests_per_second', 'requests per second', 'total_rps', 'current_rps'):
        if name in cols:
            rps = cols[name]
            break
    if not rps:
        for c in df.columns:
            low = c.lower()
            if 'requests' in low and ('s' in low or 'per' in low or 'rps' in low):
                rps = c
                break

    # name column
    name_col = None
    for candidate in ('name', 'Name', 'TYPE', 'Type'):
        if candidate in df.columns:
            name_col = candidate
            break

    return ts, avg, rps, name_col


def plot_from_csv(csv_path, out_dir):
    df = pd.read_csv(csv_path)
    ts_col, avg_col, rps_col, name_col = detect_columns(df)

    if not ts_col:
        ts_col = df.columns[0]

    # parse timestamp if possible
    try:
        df[ts_col] = pd.to_datetime(df[ts_col])
    except Exception:
        pass

    # Prefer the 'Total' row if available
    if name_col and any(str(v).lower() == 'total' for v in df[name_col].astype(str)):
        total_df = df[df[name_col].astype(str).str.lower() == 'total']
    else:
        total_df = df

    base = os.path.splitext(os.path.basename(csv_path))[0] + '-vm'

    if avg_col:
        try:
            plt.figure(figsize=(10, 4))
            plt.plot(total_df[ts_col], total_df[avg_col].astype(float), marker='o', linestyle='-')
            plt.title('Average Response Time vs Time (VM)')
            plt.xlabel('Time')
            plt.ylabel('Avg response time (ms)')
            plt.tight_layout()
            out = os.path.join(out_dir, f"{base}_latency.png")
            plt.savefig(out)
            print('Wrote', out)
        except Exception as e:
            print('Could not plot latency:', e)
    else:
        print('Average response column not found in', csv_path)

    if rps_col:
        try:
            plt.figure(figsize=(10, 4))
            plt.plot(total_df[ts_col], total_df[rps_col].astype(float), marker='o', linestyle='-')
            plt.title('RPS vs Time (VM)')
            plt.xlabel('Time')
            plt.ylabel('Requests/sec')
            plt.tight_layout()
            out = os.path.join(out_dir, f"{base}_rps.png")
            plt.savefig(out)
            print('Wrote', out)
        except Exception as e:
            print('Could not plot RPS:', e)
    else:
        print('RPS column not found in', csv_path)


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else 'locust_stats'

    repo_plots_dir = os.path.dirname(__file__)
    load_test_dir = os.path.normpath(os.path.join(repo_plots_dir, '..', 'load-test'))

    csv_path = find_history_csv(load_test_dir, base)
    if not csv_path:
        print('No matching CSV found in', load_test_dir)
        return

    plot_from_csv(csv_path, repo_plots_dir)


if __name__ == '__main__':
    main()
