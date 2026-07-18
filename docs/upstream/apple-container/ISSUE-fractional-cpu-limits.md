# Compatibility gap: fractional CPU limits

Docker Compose's positive fractional `cpus` value could be normalized but the
generic runtime parsed only integral CPUs. A macOS Linux guest already has
cgroup v2 CFS quota support, so the missing piece was a generic configuration
bridge, not host-platform emulation.

Required commits: `f7b45bf` in `apple/containerization`, then `b2a44aa` in
`apple/container`. The result uses an integral VM allocation and limits the
workload with an exact microsecond CFS quota. It excludes CPU period/quota
flags, realtime controls, cpuset, and Windows behavior.
