# Compatibility gap: CPU CFS quota and period

The generic runtime had a fractional CFS quota path but fixed its period and
could not accept a caller-provided quota. Docker Compose V2 therefore rejected
macOS-feasible `cpu_period` and `cpu_quota` before container creation.

The intended Apple delta is `e540824` in Containerization followed by
`81cc56f` in Container. It is a generic cgroup v2 CPU primitive; it excludes
Docker/Compose types, realtime scheduling, affinity, host CPU scheduling, and
Windows controls.
