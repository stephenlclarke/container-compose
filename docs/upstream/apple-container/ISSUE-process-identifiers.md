# Feature request: expose container process metadata

<!-- markdownlint-disable MD013 -->

## Feature or Enhancement Request Details

`container` should expose per-container process metadata through its typed client API and CLI. The matching `containerization` primitive reads process membership and process rows from the guest for running and paused containers; this repository should carry that data through its existing runtime, XPC, API-service, resource, and CLI layers.

Requested shape:

- Extend the codable `ContainerProcesses` resource with process metadata rows while preserving the existing container ID and process identifiers.
- Add typed process rows containing UID, PID, PPID, CPU, STIME, TTY, TIME, and CMD-compatible values.
- Keep `ContainerClient.processes(id:)` and the corresponding API-service and Linux-runtime routes as the user-facing typed API.
- Render `container top CONTAINER` as a process table when metadata is available.
- Preserve structured output through the existing `ListFormat` and `Output.render` infrastructure.
- Reject containers that are neither running nor paused.
- Keep Compose project/service selection out of this repository.

## Upstream References

- [apple/container#1769](https://github.com/apple/container/pull/1769) expands system-level status information but does not expose per-container process metadata.
- Lower-runtime issue draft:
  [ISSUE-process-identifiers.md](../apple-containerization/ISSUE-process-identifiers.md).
- Docker Compose `top` is a downstream use case, not the proposed API shape:
  <https://docs.docker.com/reference/cli/docker/compose/top/>.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
