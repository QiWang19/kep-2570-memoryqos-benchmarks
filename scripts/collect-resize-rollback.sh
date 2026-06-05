#!/bin/bash
# Collect cgroup memory knobs for the resize-rollback test pod.
# Usage: sudo ./collect-resize-rollback.sh [phase-label]
# phase-label: e.g. "BEFORE_ROLLBACK", "AFTER_ROLLBACK", "AFTER_RESIZE"

set -euo pipefail

PHASE="${1:-SNAPSHOT}"
POD_NAME="memqos-resize-rollback-test"
CONTAINER_NAME="test"

echo "=== $PHASE ($(date -Iseconds)) ==="
echo ""

# Find container cgroup path
CONTAINER_CGROUP=$(find /sys/fs/cgroup/kubepods.slice -path "*${POD_NAME}*" -name memory.high 2>/dev/null \
    | grep -v "\.scope$" | head -1 | xargs dirname 2>/dev/null || true)

if [ -z "$CONTAINER_CGROUP" ]; then
    # Try alternate naming: search by cri-o container ID
    CONTAINER_CGROUP=$(find /sys/fs/cgroup -path "*burstable*" -name memory.high 2>/dev/null \
        | while read f; do
            dir=$(dirname "$f")
            if grep -q "$CONTAINER_NAME" "$dir/cgroup.procs" 2>/dev/null; then
                echo "$dir"
                break
            fi
        done)
fi

if [ -z "$CONTAINER_CGROUP" ]; then
    echo "ERROR: Could not find container cgroup for $POD_NAME"
    echo "Trying to find any cgroup with the pod UID..."
    POD_UID=$(KUBECONFIG=/var/run/kubernetes/admin.kubeconfig kubectl get pod $POD_NAME -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
    if [ -n "$POD_UID" ]; then
        POD_UID_UNDERSCORED=$(echo "$POD_UID" | tr '-' '_')
        echo "Pod UID: $POD_UID"
        CONTAINER_CGROUP=$(find /sys/fs/cgroup -path "*${POD_UID_UNDERSCORED}*" -name memory.high 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
        if [ -z "$CONTAINER_CGROUP" ]; then
            CONTAINER_CGROUP=$(find /sys/fs/cgroup -path "*${POD_UID}*" -name memory.high 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
        fi
    fi
fi

if [ -z "$CONTAINER_CGROUP" ]; then
    echo "FATAL: Could not locate container cgroup. Exiting."
    exit 1
fi

# Derive pod-level cgroup (parent of container)
POD_CGROUP=$(dirname "$CONTAINER_CGROUP")

# Derive QoS class cgroup (parent of pod)
QOS_CGROUP=$(dirname "$POD_CGROUP")

# Derive kubepods root (parent of QoS class)
KUBEPODS_CGROUP=$(dirname "$QOS_CGROUP")

echo "--- Paths ---"
echo "  container: $CONTAINER_CGROUP"
echo "  pod:       $POD_CGROUP"
echo "  qos-class: $QOS_CGROUP"
echo "  kubepods:  $KUBEPODS_CGROUP"
echo ""

human_bytes() {
    local val="$1"
    if [ "$val" = "max" ]; then
        echo "max"
    else
        local mib=$((val / 1048576))
        echo "$val ($mib MiB)"
    fi
}

for level_name in "Container" "Pod" "QoS-class" "Kubepods-root"; do
    case "$level_name" in
        Container)    dir="$CONTAINER_CGROUP" ;;
        Pod)          dir="$POD_CGROUP" ;;
        QoS-class)    dir="$QOS_CGROUP" ;;
        Kubepods-root) dir="$KUBEPODS_CGROUP" ;;
    esac

    echo "--- $level_name level ---"
    for knob in memory.min memory.low memory.high memory.max; do
        val=$(cat "$dir/$knob" 2>/dev/null || echo "N/A")
        echo "  $knob: $(human_bytes "$val")"
    done
    echo ""
done
