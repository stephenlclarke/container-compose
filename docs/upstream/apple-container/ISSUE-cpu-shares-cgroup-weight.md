# Bug report: CPU shares are retained but ineffective in the Linux guest

## Steps to reproduce

1. Build Container with the existing generic `--cpu-shares` support and an init image containing the previous Containerization CPU-share projection.
2. Run `container run --cpu-shares 512 ... sleep infinity` on macOS.
3. Read `/sys/fs/cgroup/cpu.weight` inside the guest container.

## Problem description

The Container CLI correctly persisted the generic OCI CPU-shares value, but the lower guest runtime did not apply it. The observed cgroup v2 value remained `100` rather than runc's converted weight `59`. The functional correction is Containerization commit `ce28048`; Container commit `ac7643b` adds the end-to-end regression that protects the generic CLI path.

## Environment

- OS: macOS 26
- Xcode: 26.x toolchain
- Container: Stephen fork with Containerization `ce28048` installed in the init image

## Code of Conduct

- [ ] I agree to follow this project's Code of Conduct when filing the upstream issue.
