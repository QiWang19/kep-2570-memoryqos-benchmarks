#!/usr/bin/env python3
"""Generate pressure test charts from monitor CSV data."""

import csv
import sys
import os
from datetime import datetime

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

def parse_csv(path):
    pods = {}
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            pod = row['pod']
            if pod not in pods:
                pods[pod] = {'ts': [], 'mem': [], 'high': [], 'oom': []}
            ts = datetime.fromisoformat(row['timestamp'])
            pods[pod]['ts'].append(ts)
            pods[pod]['mem'].append(int(row['memory_current_mi']))
            pods[pod]['high'].append(int(row['memory_events_high']))
            pods[pod]['oom'].append(int(row['memory_events_oom_kill']))
    return pods

def plot_memory_all_pods(pods, outdir):
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
            ax.plot(d['ts'], d['mem'], label=pod, color=colors.get(pod), linewidth=1.5)

    ax.axhline(y=12915, color='#e74c3c', linestyle=':', alpha=0.6, label='aggressor memory.high (12,915 MiB)')
    ax.set_xlabel('Time')
    ax.set_ylabel('Memory (MiB)')
    ax.set_title('Multi-Pod Memory Under Pressure (TieredReservation ON)')
    ax.legend(loc='upper left')
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, 'pressure-memory-all-pods.png'), dpi=150)
    plt.close(fig)

def plot_aggressor_dual_axis(pods, outdir):
    if 'aggressor' not in pods:
        return
    d = pods['aggressor']
    running = [(t, m, h) for t, m, h, s in zip(d['ts'], d['mem'], d['high'],
               [1]*len(d['ts'])) if m > 0]
    if not running:
        return
    ts = [r[0] for r in running]
    mem = [r[1] for r in running]
    high = [r[2] for r in running]

    fig, ax1 = plt.subplots(figsize=(12, 6))

    memory_high_mi = 12915
    ax1.set_xlabel('Time')
    ax1.set_ylabel('Memory (MiB)', color='#e74c3c')
    ax1.plot(ts, mem, color='#e74c3c', linewidth=2, label='memory.current')
    ax1.axhline(y=memory_high_mi, color='#e74c3c', linestyle=':', alpha=0.6, label=f'memory.high ({memory_high_mi} MiB)')
    ax1.tick_params(axis='y', labelcolor='#e74c3c')
    ax1.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M'))

    ax2 = ax1.twinx()
    ax2.set_ylabel('memory.events high (cumulative)', color='#8e44ad')
    ax2.plot(ts, high, color='#8e44ad', linewidth=1.5, linestyle='--', label='high events')
    ax2.tick_params(axis='y', labelcolor='#8e44ad')

    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc='center left')

    ax1.set_title('Aggressor: memory.high Throttling')
    ax1.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, 'pressure-aggressor-throttle.png'), dpi=150)
    plt.close(fig)

def main():
    csv_path = sys.argv[1] if len(sys.argv) > 1 else 'data/multi-pod-pressure-runA-14g.csv'
    outdir = sys.argv[2] if len(sys.argv) > 2 else 'plots'
    os.makedirs(outdir, exist_ok=True)

    pods = parse_csv(csv_path)
    plot_memory_all_pods(pods, outdir)
    plot_aggressor_dual_axis(pods, outdir)
    print(f"Charts saved to {outdir}/")

if __name__ == '__main__':
    main()
