#!/usr/bin/env python3
"""Generate charts for section 6 (single-pod throttle comparison) and section 5 Run B."""

import csv
import sys
import os
from datetime import datetime

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.dates as mdates


def parse_single_pod_csv(path):
    ts, mem, high, oom = [], [], [], []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            ts.append(datetime.fromisoformat(row['timestamp']))
            mem.append(int(row['memory_current_mi']))
            high.append(int(row['memory_high_events']))
            oom.append(int(row['memory_oom_kill']))
    return {'ts': ts, 'mem': mem, 'high': high, 'oom': oom}


def parse_multi_pod_csv(path):
    pods = {}
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                pod = row['pod']
                if pod not in pods:
                    pods[pod] = {'ts': [], 'mem': [], 'high': [], 'oom': []}
                pods[pod]['ts'].append(datetime.fromisoformat(row['timestamp']))
                pods[pod]['mem'].append(int(row['memory_current_mi']))
                pods[pod]['high'].append(int(row['memory_events_high']))
                pods[pod]['oom'].append(int(row['memory_events_oom_kill']))
            except (ValueError, KeyError):
                continue
    return pods


def elapsed_minutes(ts_list):
    t0 = ts_list[0]
    return [(t - t0).total_seconds() / 60.0 for t in ts_list]


def plot_single_pod_comparison(data_8g, data_14g, outdir):
    """Overlay 8 GiB and 14 GiB single-pod memory over time with memory.high lines."""
    fig, ax = plt.subplots(figsize=(12, 6))

    t_8g = elapsed_minutes(data_8g['ts'])
    t_14g = elapsed_minutes(data_14g['ts'])

    ax.plot(t_8g, data_8g['mem'], color='#3498db', linewidth=2, label='8 GiB limit')
    ax.plot(t_14g, data_14g['mem'], color='#e74c3c', linewidth=2, label='14 GiB limit')

    ax.axhline(y=7388, color='#3498db', linestyle=':', alpha=0.6, label='memory.high 8G (7,388 MiB)')
    ax.axhline(y=12915, color='#e74c3c', linestyle=':', alpha=0.6, label='memory.high 14G (12,915 MiB)')

    ax.set_xlabel('Time (minutes)')
    ax.set_ylabel('Memory (MiB)')
    ax.set_title('Single-Pod memory.high Throttle: 8 GiB vs 14 GiB Limit')
    ax.legend(loc='center right')
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, 'single-pod-throttle-comparison.png'), dpi=150)
    plt.close(fig)
    print(f"  saved {outdir}/single-pod-throttle-comparison.png")


def plot_single_pod_dual_axis(data, memory_high_mi, limit_label, filename, outdir):
    """Dual-axis chart: memory + high events for a single pod."""
    fig, ax1 = plt.subplots(figsize=(12, 6))

    t = elapsed_minutes(data['ts'])

    ax1.set_xlabel('Time (minutes)')
    ax1.set_ylabel('Memory (MiB)', color='#e74c3c')
    ax1.plot(t, data['mem'], color='#e74c3c', linewidth=2, label='memory.current')
    ax1.axhline(y=memory_high_mi, color='#e74c3c', linestyle=':', alpha=0.6,
                label=f'memory.high ({memory_high_mi:,} MiB)')
    ax1.tick_params(axis='y', labelcolor='#e74c3c')

    ax2 = ax1.twinx()
    ax2.set_ylabel('memory.events high (cumulative)', color='#8e44ad')
    ax2.plot(t, data['high'], color='#8e44ad', linewidth=1.5, linestyle='--', label='high events')
    ax2.tick_params(axis='y', labelcolor='#8e44ad')

    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc='center left')

    ax1.set_title(f'Single-Pod Aggressor Throttling ({limit_label} limit)')
    ax1.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, filename), dpi=150)
    plt.close(fig)
    print(f"  saved {outdir}/{filename}")


def plot_runb_all_pods(pods, outdir):
    """All-pods memory chart for Run B (8 GiB aggressor + holders)."""
    fig, ax = plt.subplots(figsize=(12, 6))
    colors = {
        'aggressor': '#e74c3c',
        'guaranteed-holder': '#2ecc71',
        'burstable-holder': '#3498db',
        'besteffort-holder': '#f39c12',
    }
    for pod in ['aggressor', 'guaranteed-holder', 'burstable-holder', 'besteffort-holder']:
        if pod in pods:
            d = pods[pod]
            t = elapsed_minutes(d['ts'])
            ax.plot(t, d['mem'], label=pod, color=colors.get(pod), linewidth=1.5)

    ax.axhline(y=7388, color='#e74c3c', linestyle=':', alpha=0.6, label='aggressor memory.high (7,388 MiB)')
    ax.set_xlabel('Time (minutes)')
    ax.set_ylabel('Memory (MiB)')
    ax.set_title('Multi-Pod Memory Under Pressure — Run B (8 GiB aggressor)')
    ax.legend(loc='upper left')
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, 'pressure-runb-memory-all-pods.png'), dpi=150)
    plt.close(fig)
    print(f"  saved {outdir}/pressure-runb-memory-all-pods.png")


def plot_runb_aggressor_throttle(pods, outdir):
    """Dual-axis aggressor throttle chart for Run B."""
    if 'aggressor' not in pods:
        return
    d = pods['aggressor']
    t = elapsed_minutes(d['ts'])

    fig, ax1 = plt.subplots(figsize=(12, 6))
    memory_high_mi = 7388

    ax1.set_xlabel('Time (minutes)')
    ax1.set_ylabel('Memory (MiB)', color='#e74c3c')
    ax1.plot(t, d['mem'], color='#e74c3c', linewidth=2, label='memory.current')
    ax1.axhline(y=memory_high_mi, color='#e74c3c', linestyle=':', alpha=0.6,
                label=f'memory.high ({memory_high_mi:,} MiB)')
    ax1.tick_params(axis='y', labelcolor='#e74c3c')

    ax2 = ax1.twinx()
    ax2.set_ylabel('memory.events high (cumulative)', color='#8e44ad')
    ax2.plot(t, d['high'], color='#8e44ad', linewidth=1.5, linestyle='--', label='high events')
    ax2.tick_params(axis='y', labelcolor='#8e44ad')

    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc='center left')

    ax1.set_title('Aggressor Throttling — Run B (8 GiB limit)')
    ax1.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, 'pressure-runb-aggressor-throttle.png'), dpi=150)
    plt.close(fig)
    print(f"  saved {outdir}/pressure-runb-aggressor-throttle.png")


def main():
    basedir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    outdir = os.path.join(basedir, 'plots')
    os.makedirs(outdir, exist_ok=True)

    print("Section 6: Single-pod comparison charts")
    data_8g = parse_single_pod_csv(os.path.join(basedir, 'data/livelock-8g-test.csv'))
    data_14g = parse_single_pod_csv(os.path.join(basedir, 'data/livelock-14g-single-test.csv'))
    plot_single_pod_comparison(data_8g, data_14g, outdir)
    plot_single_pod_dual_axis(data_8g, 7388, '8 GiB', 'single-pod-8g-throttle.png', outdir)
    plot_single_pod_dual_axis(data_14g, 12915, '14 GiB', 'single-pod-14g-throttle.png', outdir)

    print("Section 5 Run B: Multi-pod 8 GiB charts")
    pods_8g = parse_multi_pod_csv(os.path.join(basedir, 'data/multi-pod-8g-test.csv'))
    plot_runb_all_pods(pods_8g, outdir)
    plot_runb_aggressor_throttle(pods_8g, outdir)


if __name__ == '__main__':
    main()
