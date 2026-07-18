# Compatibility gap: CPU CFS quota and period

The lower runtime could express an optional CFS quota but fixed the period,
preventing an explicit Linux CFS pair from reaching the macOS guest cgroup v2
`cpu.max` interface. `e540824` supplies the generic optional period after
`f7b45bf`; `81cc56f` is the separate Container consumer.

This excludes Docker/Compose APIs, realtime scheduling, CPU affinity, VM
hotplug, host scheduling, and Windows controls.
