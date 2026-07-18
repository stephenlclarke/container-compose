# Feature request: expose the generic Linux guest CPU-set resource

## Feature or enhancement request details

Container had no generic CLI/configuration path for the OCI CPU-set resource, so a macOS user could not ask the Linux guest cgroup v2 controller to constrain a container to selected CPUs.

Container commit `90b6cd1` adds `--cpuset-cpus`, persists it as `ContainerConfiguration.Resources.cpuSet`, and forwards it to the generic Containerization configuration. The required lower-runtime implementation is Containerization commit `fb1dba4`; Compose commit `2c44de78` consumes the same generic surface for standard Compose `cpuset` YAML.

This is a macOS Linux-guest resource control only. It excludes Docker/Compose models in Container source, Windows behavior, host-Linux behavior, CPU realtime settings, VM CPU allocation, and host scheduler changes.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
