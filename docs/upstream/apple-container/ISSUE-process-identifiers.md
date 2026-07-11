# Feature or Enhancement Request Details

`container` should expose per-container process identifiers through its typed
client API and CLI. The matching `containerization` primitive reads process
membership from the guest cgroup for running and paused containers; this
repository should carry that data through its existing runtime and XPC layers.

Requested shape:

- Add a codable `ContainerProcesses` resource containing the container ID and
  process identifiers.
- Add `ContainerClient.processes(id:)` and the corresponding API-service and
  Linux-runtime routes.
- Add `container top CONTAINER` with table, JSON, YAML, and TOML output through
  the existing `ListFormat` and `Output.render` infrastructure.
- Reject containers that are neither running nor paused.
- Keep Compose project/service selection and Docker-shaped process columns out
  of this repository.

## Upstream References

- [apple/container#1769](https://github.com/apple/container/pull/1769) expands
  system-level status information but does not expose per-container process
  membership.
- Lower-runtime issue draft:
  [ISSUE-process-identifiers.md](../apple-containerization/ISSUE-process-identifiers.md).
- Docker Compose `top` is a downstream use case, not the proposed API shape:
  <https://docs.docker.com/reference/cli/docker/compose/top/>.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
