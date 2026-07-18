# Feature request: render OCI unlimited CPU quota as cgroup v2 max

## Feature or enhancement request details

OCI represents an unlimited CPU CFS quota with a negative quota value, while cgroup v2 requires the literal `max` in `cpu.max`. The Linux guest cgroup writer emitted the raw negative value, causing an invalid write rather than creating an unlimited limit.

Containerization commit `46c0921` converts only a negative OCI CPU quota to `max`, preserving the supplied CFS period. Container commit `29c3cc8` is the separate generic CLI consumer that maps `--cpus 0` to the existing OCI unlimited sentinel. Compose commit `52b0b874` confirms that Compose V2 normalizes `cpus: 0` to an omitted runtime limit.

The requested change is intentionally limited to the macOS Linux guest's generic OCI/cgroup v2 bridge. It does not add Docker or Compose APIs, Windows behavior, Linux-host behavior, realtime scheduling, cpusets, VM CPU allocation, or host scheduler controls.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
