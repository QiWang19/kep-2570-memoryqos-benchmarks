#!/bin/bash
# Monitor capacity-pressure test: pod memory, cgroup state, kubelet health, node conditions.
# Usage: ./monitor-capacity-pressure.sh <output-csv> [max-seconds]
# Default max: 900s (15 min). Polls every 2s.

set -euo pipefail

export KUBECONFIG=/var/run/kubernetes/admin.kubeconfig
OUTPUT="${1:-/dev/stdout}"
MAX_SECONDS="${2:-900}"
PODS="guaranteed-holder-1 guaranteed-holder-2 guaranteed-holder-3 guaranteed-holder-4 burstable-holder besteffort-holder besteffort-aggressor"
START=$(date +%s)

find_container_cgroup() {
    local pod_name="$1"
    local pod_uid pod_uid_u qos pod_parent qos_path pod_cgroup

    pod_uid=$(kubectl get pod "$pod_name" -o jsonpath='{.metadata.uid}' 2>/dev/null) || return 1
    pod_uid_u=$(echo "$pod_uid" | tr '-' '_')
    qos=$(kubectl get pod "$pod_name" -o jsonpath='{.status.qosClass}' 2>/dev/null) || return 1

    case "$qos" in
        Guaranteed) pod_parent="/sys/fs/cgroup/kubepods.slice"; qos_path="kubepods-pod${pod_uid_u}.slice" ;;
        Burstable)  pod_parent="/sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice"; qos_path="kubepods-burstable-pod${pod_uid_u}.slice" ;;
        BestEffort) pod_parent="/sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice"; qos_path="kubepods-besteffort-pod${pod_uid_u}.slice" ;;
    esac

    pod_cgroup="$pod_parent/$qos_path"
    for d in "$pod_cgroup"/crio-*.scope; do
        [ -d "$d" ] && echo "$d" && return 0
    done
    return 1
}

# Resolve cgroup paths once (re-resolve for aggressor later)
declare -A CGROUPS
for pod in $PODS; do
    cg=$(find_container_cgroup "$pod" 2>/dev/null) || true
    CGROUPS[$pod]="$cg"
done

{
echo "timestamp,elapsed_s,pod,status,memory_current_mi,memory_min_mi,memory_low_mi,memory_high,memory_events_high,memory_events_oom_kill,kubepods_memory_min_mi,burstable_memory_low_mi,mem_available_mi,node_memory_pressure,kubelet_api_ms"

while true; do
    now=$(date +%s)
    elapsed=$((now - START))
    [ $elapsed -ge $MAX_SECONDS ] && break

    ts=$(date -Iseconds)

    # Node-level checks (once per cycle)
    kubepods_min=$(cat /sys/fs/cgroup/kubepods.slice/memory.min 2>/dev/null || echo "0")
    kubepods_min_mi=$((kubepods_min / 1048576))
    burstable_low=$(cat /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/memory.low 2>/dev/null || echo "0")
    burstable_low_mi=$((burstable_low / 1048576))
    mem_avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mem_avail_mi=$((mem_avail_kb / 1024))

    # kubelet API latency
    api_start=$(date +%s%N)
    node_json=$(kubectl get node 127.0.0.1 -o json 2>/dev/null) || node_json=""
    api_end=$(date +%s%N)
    api_ms=$(( (api_end - api_start) / 1000000 ))

    # Node MemoryPressure condition
    mem_pressure="unknown"
    if [ -n "$node_json" ]; then
        mem_pressure=$(echo "$node_json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for c in d.get('status',{}).get('conditions',[]):
        if c.get('type') == 'MemoryPressure':
            print(c.get('status','Unknown'))
            break
    else:
        print('NotFound')
except: print('Error')
" 2>/dev/null || echo "Error")
    fi

    for pod in $PODS; do
        status=$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

        # Try to resolve cgroup if not yet found (for late-deployed aggressor)
        cg="${CGROUPS[$pod]}"
        if [ -z "$cg" ] || [ ! -d "$cg" ]; then
            cg=$(find_container_cgroup "$pod" 2>/dev/null) || true
            CGROUPS[$pod]="$cg"
        fi

        if [ -n "$cg" ] && [ -d "$cg" ]; then
            mem_cur=$(cat "$cg/memory.current" 2>/dev/null || echo "0")
            mem_cur_mi=$((mem_cur / 1048576))
            mem_min=$(cat "$cg/memory.min" 2>/dev/null || echo "0")
            mem_min_mi=$((mem_min / 1048576))
            mem_low=$(cat "$cg/memory.low" 2>/dev/null || echo "0")
            mem_low_mi=$((mem_low / 1048576))
            mem_high=$(cat "$cg/memory.high" 2>/dev/null || echo "max")
            high_events=$(grep "^high " "$cg/memory.events" 2>/dev/null | awk '{print $2}' || echo "0")
            oom_events=$(grep "oom_kill" "$cg/memory.events" 2>/dev/null | awk '{print $2}' || echo "0")
        else
            mem_cur_mi=0; mem_min_mi=0; mem_low_mi=0; mem_high="n/a"
            high_events=0; oom_events=0
        fi

        echo "$ts,$elapsed,$pod,$status,$mem_cur_mi,$mem_min_mi,$mem_low_mi,$mem_high,$high_events,$oom_events,$kubepods_min_mi,$burstable_low_mi,$mem_avail_mi,$mem_pressure,$api_ms"
    done

    sleep 2
done
} > "$OUTPUT"

echo "Monitoring complete ($elapsed s). Output: $OUTPUT" >&2
