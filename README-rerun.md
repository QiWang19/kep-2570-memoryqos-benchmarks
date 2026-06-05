# KEP-2570: MemoryQoS Benchmark Results (Beta)

Beta graduation benchmarks on a build that includes the BestEffort memory.high fix ([kubernetes/kubernetes#138139](https://github.com/kubernetes/kubernetes/pull/138139)), the rollback cleanup PRs ([#138903](https://github.com/kubernetes/kubernetes/pull/138903), [#139377](https://github.com/kubernetes/kubernetes/pull/139377)), and all other MemoryQoS changes merged to master through 2026-06-01.

See [README.md](README.md) for the Alpha benchmark results run on commit [c8468eacac5](https://github.com/sohankunkerkar/kubernetes/commit/c8468eacac5).

---

## Test Environment

| Component | Version |
|-----------|---------|
| Kernel | 7.0.9-205.fc44.x86_64 |
| Kubelet | v1.37.0-alpha.0.1256+dc7be641101f4a-dirty (master, includes [dc7be641](https://github.com/kubernetes/kubernetes/commit/dc7be641101f4ad0ba4d13478e65839b0fa7deb2)) |
| Container Runtime | CRI-O 1.34.3 ,CRI-O 1.37.0 |
| Cluster | local-up-cluster.sh, single node |
| cgroup | v2 |
| Node allocatable memory | 32388480Ki (30.9 GiB) |

Kubelet configuration: `MemoryQoS=true`, `memoryReservationPolicy=TieredReservation`, `memoryThrottlingFactor=0.9` (default).

Data was collected by polling cgroup files every 1s from the container's cgroup path on the node. Collection script: [`scripts/collect-cgroup-data.sh`](scripts/collect-cgroup-data.sh).

---

## 1. memory.high Throttle Behavior

**Pod spec**: [`manifests/throttle-test-pod.yaml`](manifests/throttle-test-pod.yaml) - Burstable pod, requests=256Mi, limits=512Mi.

`memory.high` = floor[(256 + 0.9 * (512 - 256)) / 4096] * 4096 = 486 MiB (510025728 bytes)

| Metric | alpha | beta |
|--------|-------------|-------|
| Time to reach memory.high | ~49s | ~41s |
| Peak memory | 511 MiB | 511 MiB |
| Total `memory.events` high counter | 3,596 | 4,234 |
| Duration to OOM-kill | 71s | 54s |
| Pod exit reason | OOMKilled | OOMKilled |

Behavior is consistent: the container progresses through throttling to OOM-kill. Timing variation is expected across runs (the alpha repeated trials showed 59-65s, ~9% spread).

Raw data: [`data/01-throttle-test-factor-0.9-v2.csv`](data/01-throttle-test-factor-0.9-v2.csv)

---

## 2. Tiered Memory Protection

Guaranteed pods get `memory.min` (hard protection). Burstable pods get `memory.low` (soft protection). BestEffort pods now get `memory.high` set (fixed in [#138139](https://github.com/kubernetes/kubernetes/pull/138139)).

| QoS Class | memory.min | memory.low | memory.high |
|-----------|-----------|-----------|------------|
| Guaranteed (req=lim=256Mi) | 256 MiB | 0 | max |
| Burstable (req=128Mi, lim=256Mi) | 0 | 128 MiB | 243 MiB |
| **BestEffort** | **0** | **0** | **28,556 MiB** |

**BestEffort fix**: In the alpha run, `memory.high` was `max` (no throttling). Now it is correctly set to `floor[(0.9 * node_allocatable) / pageSize] * pageSize` per the KEP formula. This was fixed by [kubernetes/kubernetes#138139](https://github.com/kubernetes/kubernetes/pull/138139) — the code previously treated `request == limit` (both 0) as Guaranteed, skipping memory.high.

### Multi-container pod (Burstable)

| Resource | memory.low | memory.high |
|----------|-----------|------------|
| Container A (req=128Mi, lim=256Mi) | 128 MiB | 243 MiB |
| Container B (req=64Mi, lim=128Mi) | 64 MiB | 121 MiB |
| **Pod total** | **192 MiB** | -- |

### Cgroup hierarchy

| Level | memory.min | memory.low |
|-------|-----------|-----------|
| kubepods.slice | 518 MiB | 0 |
| kubepods-burstable.slice | 0 | 262 MiB |

kubepods root `memory.min` = sum of Guaranteed `memory.min` + Burstable `memory.low`: 256 MiB (guaranteed-test) + 192 MiB (multi-container) + 70 MiB (coredns) = 518 MiB. Burstable QoS `memory.low` = 192 MiB + 70 MiB = 262 MiB. The parent must cover both hard and soft protection for the hierarchy to be effective.

Raw data: [`data/v2-tiered-protection.txt`](data/v2-tiered-protection.txt)

---

## 3. Rollback Safety

Burstable pod (requests=128Mi, limits=256Mi). Disabled MemoryQoS by setting `MemoryQoS: false` and removing `memoryReservationPolicy`, then restarted kubelet.

| Level | Knob | Before | After | Status |
|-------|------|--------|-------|--------|
| kubepods root | memory.min | 198 MiB | **0** | Cleared at kubelet startup ([#138903](https://github.com/kubernetes/kubernetes/pull/138903)) |
| burstable QoS | memory.low | 198 MiB | **0** | Cleared at kubelet startup ([#138903](https://github.com/kubernetes/kubernetes/pull/138903)) |
| pod level | memory.low | 128 MiB | 128 MiB | Stale — neutralized (parent=0 wins) |
| container | memory.low | 128 MiB | 128 MiB | Stale — neutralized (parent=0 wins) |
| container | memory.high | 243 MiB | 243 MiB | Stale — cleared on container restart or InPlacePodResize ([#139377](https://github.com/kubernetes/kubernetes/pull/139377)) |

QoS-class level cleanup works correctly. Pod-level and container-level values persist but are effectively neutralized because cgroup v2 memory protection is hierarchical (parent=0 wins). Container-level `memory.high` persists until the container is restarted or resized via InPlacePodResize.

Raw data: [`data/v2-rollback-safety-test.txt`](data/v2-rollback-safety-test.txt)

---

## 4. InPlacePodResize + Rollback

Burstable pod (requests=128Mi, limits=256Mi) with `resizePolicy: NotRequired`. Created with MemoryQoS enabled, then disabled MemoryQoS and restarted kubelet, then triggered in-place resize (128Mi/256Mi → 192Mi/384Mi).

| Level | Knob | Before Rollback | After Rollback | After Resize | Status |
|-------|------|-----------------|----------------|--------------|--------|
| kubepods root | memory.min | 198 MiB | **0** | 0 | Cleared at kubelet startup ([#138903](https://github.com/kubernetes/kubernetes/pull/138903)) |
| burstable QoS | memory.low | 198 MiB | **0** | 0 | Cleared at kubelet startup ([#138903](https://github.com/kubernetes/kubernetes/pull/138903)) |
| pod level | memory.low | 128 MiB | 128 MiB | 128 MiB | Stale — neutralized (parent=0 wins) |
| pod level | memory.max | 256 MiB | 256 MiB | **384 MiB** | Updated by resize |
| container | memory.low | 128 MiB | 128 MiB | 128 MiB | Stale — neutralized (parent=0 wins) |
| container | memory.high | 243 MiB | 243 MiB | **max** | Cleared by resize ([#139377](https://github.com/kubernetes/kubernetes/pull/139377)) |
| container | memory.max | 256 MiB | 256 MiB | **384 MiB** | Updated by resize |

InPlacePodResize clears stale `memory.high` after rollback without requiring a container restart. Requires a container runtime that passes the `Unified` map through `UpdateContainerResources` (e.g. CRI-O >= 1.36).

Raw data: [`data/v2-resize-rollback-test.txt`](data/v2-resize-rollback-test.txt)

---

## 5. Multi-Pod Memory Protection Under Pressure (TieredReservation ON)

**Pod specs**: [`manifests/pressure-test-holders.yaml`](manifests/pressure-test-holders.yaml), [`manifests/pressure-test-aggressor.yaml`](manifests/pressure-test-aggressor.yaml)

Kubelet config: `MemoryQoS=true`, `memoryReservationPolicy=TieredReservation`. Node allocatable: 30.9 GiB.

| Pod | QoS | Requests/Limits | Workload | Protection |
|-----|-----|-----------------|----------|------------|
| guaranteed-holder | Guaranteed | 256Mi/256Mi | hold 100Mi | memory.min=256Mi |
| burstable-holder | Burstable | 128Mi/512Mi | hold 100Mi | memory.low=128Mi |
| besteffort-holder | BestEffort | none | hold 200Mi | none |

### Run A: aggressor with 14 GiB limit

Aggressor: Burstable, requests=128Mi, limits=14Gi, allocating 50Mi/0.5s (~100Mi/s).

| Metric | Value |
|--------|-------|
| Aggressor memory.high | 12,915 Mi (~12.6 GiB) |
| Time to reach memory.high | ~2m21s |
| Peak aggressor memory | ~13,362 Mi (~13.0 GiB) |
| Aggressor memory.events high (at 10min) | 293,678 |
| Aggressor outcome | Throttled at memory.high, still running at 10min |
| Node total RAM | 31.7 GiB |
| Node available memory at test start | ~13 GiB |
| Kill order | none — all pods survived |

The aggressor ramped linearly from 104Mi to ~12,860Mi in ~2m21s with `high=0`. Once it crossed `memory.high` (~12.6 GiB), the kernel began throttling: memory plateaued at ~13.1-13.3 GiB while the `high` event counter climbed rapidly (3,058 → 293,678 over ~8 minutes). The aggressor was still running when the monitor timed out at 10 minutes — `memory.high` throttling effectively capped it without OOM-killing.

All three holder pods remained stable throughout (guaranteed: 106Mi, burstable: 104-108Mi, besteffort: 204Mi, all `high=0`, `oom_kill=0`).

![All pods memory under pressure](plots/pressure-memory-all-pods.png)

![Aggressor memory.high throttling](plots/pressure-aggressor-throttle.png)

Raw data: [`data/multi-pod-pressure-runA-14g.csv`](data/multi-pod-pressure-runA-14g.csv), [`data/multi-pod-pressure-runA.txt`](data/multi-pod-pressure-runA.txt)

Monitor script: [`scripts/monitor-pressure-test.sh`](scripts/monitor-pressure-test.sh). Plot script: [`scripts/plot-pressure-test.py`](scripts/plot-pressure-test.py)

---

## Changes from Alpha Run

| Test | alpha | beta | Impact |
|------|-------------|-------|--------|
| BestEffort memory.high | `max` | 28,556 MiB (0.9 * allocatable) | **Fixed** — BestEffort containers now get throttled per KEP formula |
| Throttle behavior | OOMKilled in 71s | OOMKilled in 54s | No change — timing varies across runs |
| Tiered protection | Correct | Correct | No change |
| Multi-container | Correct | Correct | No change |
| Cgroup hierarchy | Correct | Correct | No change |
| Rollback: QoS class | Cleared via reconcile loop | Cleared at kubelet startup | **Improved** — cleanup via startup dbus calls |
| Rollback: container memory.high | Not tested | Stale, cleared on restart/resize | **New** — confirmed stale value behavior |
| Rollback: InPlacePodResize | Not tested | Clears stale memory.high to max | **New** — non-disruptive remediation confirmed |
| Multi-pod pressure (Run A) | Not tested | Aggressor throttled at memory.high, all pods survived | **New** — validates memory.high throttling under pressure |

---

## References

- [KEP-2570: Memory QoS](https://github.com/kubernetes/enhancements/issues/2570)
- [BestEffort memory.high fix — #138139](https://github.com/kubernetes/kubernetes/pull/138139)
- [Rollback: clear stale memory.min/memory.low — #138903](https://github.com/kubernetes/kubernetes/pull/138903)
- [Rollback: clear stale memory.high — #139377](https://github.com/kubernetes/kubernetes/pull/139377)
