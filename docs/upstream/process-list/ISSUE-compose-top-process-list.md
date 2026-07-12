# Feature request: support `container compose top`

<!-- markdownlint-disable MD013 -->

## Feature or Enhancement Request Details

Docker Compose exposes `docker compose top [SERVICES...]` to display the running processes for project service containers. The current `stephenlclarke` runtime stack exposes process metadata through `containerization` and `apple/container`, so `container-compose` can implement service selection and Docker-shaped output through the direct API.

References:

- Docker Compose `top`: <https://docs.docker.com/reference/cli/docker/compose/top/>
- Docker `container top`: <https://docs.docker.com/reference/cli/docker/container/top/>
- Container handoffs: [ISSUE-process-identifiers.md](../apple-container/ISSUE-process-identifiers.md) and [PR-process-identifiers.md](../apple-container/PR-process-identifiers.md)
- Lower-runtime handoffs: [ISSUE-process-identifiers.md](../apple-containerization/ISSUE-process-identifiers.md) and [PR-process-identifiers.md](../apple-containerization/PR-process-identifiers.md)

## Proposed Behavior

- Accept `container compose top [SERVICES...]`.
- Resolve selected services to Compose-managed service containers, including discovered replicas and custom `container_name` values.
- Call `ContainerClient.processes(id:)` through a direct API adapter.
- Emit Docker Compose-style per-container process sections.
- Include UID, PID, PPID, CPU, STIME, TTY, TIME, and CMD columns when the current runtime returns process metadata.

## Minimal Example

```sh
container compose top api worker
```

Expected behavior:

- The plugin lists running process metadata for each selected service container.
- Output follows Docker Compose's per-container process-table layout.
- Stock Apple builds remain runtime-gated until equivalent process metadata APIs and matching guest init-image delivery land upstream.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
