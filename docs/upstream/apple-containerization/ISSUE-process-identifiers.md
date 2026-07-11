# Feature or Enhancement Request Details

`LinuxContainer` should expose the process identifiers currently assigned to a
running or paused container. Generic clients need a runtime-owned process view
for diagnostics and orchestration without reading guest cgroup files from the
macOS host.

Requested shape:

- Add a `LinuxContainer.processIdentifiers()` API that is valid while the
  container is running or paused.
- Add a typed sandbox-agent RPC that returns process identifiers for one
  container.
- Read and validate `cgroup.procs` in `vminitd`, returning sorted `Int32` values.
- Preserve existing state errors for containers that are not running or paused.
- Keep Docker and Docker Compose output policy out of `containerization`.

## Upstream References

- The Linux kernel documents `cgroup.procs` as the process membership interface
  for a cgroup: <https://docs.kernel.org/admin-guide/cgroup-v2.html>.
- [apple/container#1769](https://github.com/apple/container/pull/1769) expands
  system-level status information but does not expose per-container process
  membership.
- Docker Compose `top` is one downstream consumer of this generic primitive:
  <https://docs.docker.com/reference/cli/docker/compose/top/>.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
