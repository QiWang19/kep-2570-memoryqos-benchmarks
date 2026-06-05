#!/bin/bash
# Monitor all pressure test pods: memory.current, memory.events, pod status
# Usage: ./monitor-pressure-test.sh <output-file>
# Runs until all non-guaranteed pods are terminated or 10 minutes elapsed.

set -euo pipefail

export KUBECONFIG=/var/run/kubernetes/admin.kubeconfig
OUTPUT="${1:-/dev/stdout}"
PODS="guaranteed-holder burstable-holder besteffort-holder aggressor"
MAX_SECONDS=600
START=$(date +%s)

human() {
    local val="$1"
    if [ "$val" = "max" ]; then echo "max"
    else echo "$((val / 1048576))Mi"
    fi
}

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

# Resolve cgroup paths once
declare -A CGROUPS
for pod in $PODS; do
    cg=$(find_container_cgroup "$pod" 2>/dev/null) || true
    CGROUPS[$pod]="$cg"
done

{
echo "timestamp,pod,status,memory_current_mi,memory_events_high,memory_events_oom_kill"

while true; do
    now=$(date +%s)
    elapsed=$((now - START))
    [ $elapsed -ge $MAX_SECONDS ] && break

    ts=$(date -Iseconds)
    all_done=true

    for pod in $PODS; do
        status=$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Gone")
        cg="${CGROUPS[$pod]}"

        if [ -n "$cg" ] && [ -d "$cg" ]; then
            mem_cur=$(cat "$cg/memory.current" 2>/dev/null || echo "0")
            mem_cur_mi=$((mem_cur / 1048576))
            high_events=$(grep "^high " "$cg/memory.events" 2>/dev/null | awk '{print $2}' || echo "0")
            oom_events=$(grep "oom_kill" "$cg/memory.events" 2>/dev/null | awk '{print $2}' || echo "0")
        else
            mem_cur_mi=0
            high_events=0
            oom_events=0
        fi

        echo "$ts,$pod,$status,${mem_cur_mi},${high_events},${oom_events}"

        if [ "$pod" != "guaranteed-holder" ] && [ "$status" = "Running" ]; then
            all_done=false
        fi
    done

    $all_done && break
    sleep 2
done
} > "$OUTPUT"

echo "Monitoring complete. Output: $OUTPUT" >&2
