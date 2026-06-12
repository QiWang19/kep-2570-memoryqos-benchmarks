#!/bin/bash
# Deploy capacity-pressure test pods ONE AT A TIME with health checks.
# Usage: ./deploy-capacity-pressure.sh
#
# Deploys 4 Guaranteed (7Gi each, 1Gi actual), 1 Burstable, 1 BestEffort.
# sum(memory.min) = 28 GiB ≈ 90% of allocatable (30.9 GiB).
# Actual memory usage: ~5 GiB total — safe on a 32 GiB laptop.

set -euo pipefail

export KUBECONFIG=/var/run/kubernetes/admin.kubeconfig
MANIFEST_DIR="$(cd "$(dirname "$0")/../manifests" && pwd)"

check_node_health() {
    local mem_avail_kb mem_avail_mi
    mem_avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mem_avail_mi=$((mem_avail_kb / 1024))
    echo "  MemAvailable: ${mem_avail_mi}Mi"

    if [ "$mem_avail_mi" -lt 2048 ]; then
        echo "  WARNING: MemAvailable < 2Gi — aborting to protect the node."
        exit 1
    fi

    if ! kubectl get nodes &>/dev/null; then
        echo "  ERROR: kubelet API not responding — aborting."
        exit 1
    fi
    echo "  kubelet API: OK"
}

wait_for_pod() {
    local pod="$1" timeout=60 elapsed=0
    echo "  Waiting for $pod to be Running..."
    while [ $elapsed -lt $timeout ]; do
        phase=$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$phase" = "Running" ]; then
            echo "  $pod: Running"
            return 0
        elif [ "$phase" = "Failed" ] || [ "$phase" = "Unknown" ]; then
            echo "  $pod: $phase — check pod events"
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "  $pod: timed out (last phase: $phase)"
    return 1
}

deploy_pod() {
    local pod_name="$1"
    echo ""
    echo "=== Deploying $pod_name ==="
    check_node_health

    # Extract this pod's YAML and apply it
    kubectl apply -f - <<EOF
$(python3 -c "
import yaml, sys
with open('$MANIFEST_DIR/capacity-pressure-holders.yaml') as f:
    for doc in yaml.safe_load_all(f):
        if doc and doc.get('metadata',{}).get('name') == '$pod_name':
            yaml.dump(doc, sys.stdout, default_flow_style=False)
            break
")
EOF

    wait_for_pod "$pod_name"
    sleep 3
    check_node_health
}

echo "=== Capacity Pressure Test: Safe Sequential Deployment ==="
echo "Node allocatable: $(kubectl get node 127.0.0.1 -o jsonpath='{.status.allocatable.memory}')"
echo ""
check_node_health

# Deploy Guaranteed pods one at a time
for i in 1 2 3 4; do
    deploy_pod "guaranteed-holder-$i"
done

# Deploy Burstable and BestEffort
deploy_pod "burstable-holder"
deploy_pod "besteffort-holder"

echo ""
echo "=== All holder pods deployed ==="
kubectl get pods -o wide
echo ""
echo "Cgroup state:"
echo "  kubepods memory.min: $(($(cat /sys/fs/cgroup/kubepods.slice/memory.min) / 1048576))Mi"
echo "  burstable memory.low: $(($(cat /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/memory.low) / 1048576))Mi"
check_node_health
echo ""
echo "Ready for monitoring. Next steps:"
echo "  1. ./scripts/monitor-capacity-pressure.sh data/capacity-pressure-steady.csv 300"
echo "  2. kubectl apply -f manifests/capacity-pressure-aggressor.yaml"
echo "  3. ./scripts/monitor-capacity-pressure.sh data/capacity-pressure-test.csv 600"
