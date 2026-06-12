#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/var/run/kubernetes/admin.kubeconfig

OUTPUT="${1:-/dev/stdout}"
MAX_SECONDS="${2:-300}"
PODS="guaranteed-soft-holder burstable-soft-holder besteffort-aggressor"
START=$(date +%s)

find_container_cgroup() {
    local pod_name="$1"
    local pod_uid pod_uid_u qos pod_parent qos_path pod_cgroup

    pod_uid=$(kubectl get pod "$pod_name" -o jsonpath='{.metadata.uid}' 2>/dev/null) || return 1
    pod_uid_u="${pod_uid//-/_}"
    qos=$(kubectl get pod "$pod_name" -o jsonpath='{.status.qosClass}' 2>/dev/null) || return 1

    case "$qos" in
        Guaranteed) pod_parent="/sys/fs/cgroup/kubepods.slice"; qos_path="kubepods-pod${pod_uid_u}.slice" ;;
        Burstable) pod_parent="/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice"; qos_path="kubepods-burstable-pod${pod_uid_u}.slice" ;;
        BestEffort) pod_parent="/sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice"; qos_path="kubepods-besteffort-pod${pod_uid_u}.slice" ;;
    esac

    pod_cgroup="$pod_parent/$qos_path"
    for d in "$pod_cgroup"/crio-*.scope; do
        [ -d "$d" ] && echo "$d" && return 0
    done
    return 1
}

read_stat() {
    local file="$1" key="$2"
    awk -v key="$key" '$1 == key {print $2}' "$file" 2>/dev/null || echo "0"
}

read_event() {
    local file="$1" key="$2"
    awk -v key="$key" '$1 == key {print $2}' "$file" 2>/dev/null || echo "0"
}

declare -A CGROUPS

echo "timestamp,elapsed_s,pod,status,memory_current_mi,memory_min_mi,memory_low_mi,memory_max,memory_events_low,memory_events_max,memory_events_oom_kill,anon_mi,file_mi,node_mem_available_mi,node_memory_pressure_some_avg10,kubelet_api_ms" > "$OUTPUT"

while true; do
    now=$(date +%s)
    elapsed=$((now - START))
    [ "$elapsed" -ge "$MAX_SECONDS" ] && break

    timestamp=$(date -Iseconds)
    mem_available_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    mem_available_mi=$((mem_available_kb / 1024))
    pressure_some=$(awk '/^some/ {sub("avg10=", "", $2); print $2}' /proc/pressure/memory 2>/dev/null || echo "0")

    api_start=$(date +%s%N)
    node_json=$(kubectl get node 127.0.0.1 -o json 2>/dev/null) || node_json=""
    api_end=$(date +%s%N)
    api_ms=$(((api_end - api_start) / 1000000))

    memory_pressure="unknown"
    if [ -n "$node_json" ]; then
        memory_pressure=$(printf '%s' "$node_json" | python3 -c 'import json,sys; print(next((c["status"] for c in json.load(sys.stdin)["status"]["conditions"] if c["type"] == "MemoryPressure"), "NotFound"))' 2>/dev/null || echo "Error")
    fi

    for pod in $PODS; do
        status=$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        cgroup="${CGROUPS[$pod]:-}"
        if [ -z "$cgroup" ] || [ ! -d "$cgroup" ]; then
            cgroup=$(find_container_cgroup "$pod" 2>/dev/null) || true
            CGROUPS[$pod]="$cgroup"
        fi

        if [ -n "$cgroup" ] && [ -d "$cgroup" ]; then
            current=$(( $(cat "$cgroup/memory.current" 2>/dev/null || echo 0) / 1048576 ))
            minimum=$(( $(cat "$cgroup/memory.min" 2>/dev/null || echo 0) / 1048576 ))
            low=$(( $(cat "$cgroup/memory.low" 2>/dev/null || echo 0) / 1048576 ))
            maximum=$(cat "$cgroup/memory.max" 2>/dev/null || echo "n/a")
            events_low=$(read_event "$cgroup/memory.events" low)
            events_max=$(read_event "$cgroup/memory.events" max)
            events_oom_kill=$(read_event "$cgroup/memory.events" oom_kill)
            anon=$(( $(read_stat "$cgroup/memory.stat" anon) / 1048576 ))
            file=$(( $(read_stat "$cgroup/memory.stat" file) / 1048576 ))
        else
            current=0
            minimum=0
            low=0
            maximum="n/a"
            events_low=0
            events_max=0
            events_oom_kill=0
            anon=0
            file=0
        fi

        echo "$timestamp,$elapsed,$pod,$status,$current,$minimum,$low,$maximum,$events_low,$events_max,$events_oom_kill,$anon,$file,$mem_available_mi,$pressure_some,$api_ms" >> "$OUTPUT"
    done

    sleep 1
done

echo "Monitoring complete (${elapsed}s). Output: $OUTPUT" >&2
