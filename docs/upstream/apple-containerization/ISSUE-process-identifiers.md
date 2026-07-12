# Feature request: expose Linux container process metadata

<!-- markdownlint-disable MD013 -->

## Feature or Enhancement Request Details

`LinuxContainer` should expose process metadata for a running or paused container. Generic callers need a runtime-owned process view for diagnostics and orchestration without reading guest cgroup or `/proc` files from the macOS host.

Requested shape:

- Keep `LinuxContainer.processIdentifiers()` for callers that only need PID membership.
- Add `LinuxContainer.processes()` returning typed process rows.
- Add a sandbox-agent RPC response field for process rows while preserving the existing PID field.
- Read cgroup membership in `vminitd`, then collect UID, PID, PPID, CPU, STIME, TTY, elapsed TIME, and command from guest `/proc`.
- Preserve existing state errors for containers that are not running or paused.
- Keep Docker and Docker Compose output policy out of `containerization`.

## Upstream References

- The Linux kernel documents `cgroup.procs` as the process membership interface for a cgroup: <https://docs.kernel.org/admin-guide/cgroup-v2.html>.
- Linux procfs exposes process status, command, uptime, and stat fields used to build the metadata rows: <https://docs.kernel.org/filesystems/proc.html>.
- [apple/container#1769](https://github.com/apple/container/pull/1769) expands system-level status information but does not expose per-container process metadata.
- Docker Compose `top` is one downstream consumer of this generic primitive: <https://docs.docker.com/reference/cli/docker/compose/top/>.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
