# Feature request: apply OCI CPU shares as cgroup v2 weight

## Feature or enhancement request details

Containerization already projected generic OCI `LinuxCPU.shares`, but the Linux guest cgroup manager did not consume that field. As a result, a configured relative CPU share value had no runtime effect: `cpu.weight` remained the cgroup v2 default (`100`).

Containerization commit `ce28048` completes the generic OCI-to-cgroup-v2 bridge. It converts the OCI cgroup-v1-style share scale to cgroup v2's weight scale using runc's conversion and writes `cpu.weight` only when the caller supplied a nonzero share value. The required prior Containerization configuration projection is `d5e6c22`; Container commit `ac7643b` adds the end-to-end consumer regression; Compose commit `82c74e82` provides Docker Compose V2 YAML/config/dry-run parity coverage.

This is limited to the macOS Linux guest's generic cgroup resource application. It excludes Docker/Compose data types, Windows behavior, host-Linux behavior, CPU realtime controls, cpuset configuration, VM CPU allocation, and host scheduler settings.

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
