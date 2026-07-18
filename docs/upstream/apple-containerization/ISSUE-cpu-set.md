# Feature request: apply generic OCI CPU sets in the cgroup v2 guest

## Feature or enhancement request details

The macOS Linux guest has the cgroup v2 `cpuset` controller, but Containerization did not expose or apply a generic CPU-set value. Consequently, a caller could not constrain a container to a CPU list even though the guest kernel and cgroup hierarchy support it.

Containerization commit `fb1dba4` adds the generic `LinuxContainer.Configuration.cpuSet` resource and projects it to OCI `LinuxCPU.cpus`. The cgroup v2 manager initializes `cpuset.mems` from the parent effective memory-node set when the caller has not supplied one, then writes `cpuset.cpus`. Container commit `90b6cd1` adds the generic `--cpuset-cpus` consumer, and Compose commit `2c44de78` maps the standard Compose `cpuset` service field with Docker Compose V2 parity coverage.

The change is restricted to the macOS-hosted Linux guest's generic OCI/cgroup-v2 resource path. It does not introduce Docker or Compose types, Windows behavior, host-Linux behavior, CPU realtime controls, VM vCPU allocation, or host scheduler configuration.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
