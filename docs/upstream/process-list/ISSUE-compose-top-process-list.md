# Feature request: support `container compose top`

<!-- markdownlint-disable MD013 -->

## Feature or enhancement request details

Docker Compose exposes `docker compose top [SERVICES...]` to display the running processes for project service containers. `container-compose` previously rejected `top` because released upstream `apple/container` did not expose a process-listing API.

The local integration stack now exposes PID-only process identifiers through `containerization` and `apple/container`, so the plugin can implement service selection and service-aware output through the direct API.

References:

- Docker Compose `top`: <https://docs.docker.com/reference/cli/docker/compose/top/>
- Docker `container top`: <https://docs.docker.com/reference/cli/docker/container/top/>
- Container handoff: `docs/upstream/process-list/ISSUE-container-process-identifiers.md` and `docs/upstream/process-list/PR-container-process-identifiers.md` in the `container` fork
- Lower runtime handoff: `docs/upstream/process-list/ISSUE-containerization-process-identifiers.md` and `docs/upstream/process-list/PR-containerization-process-identifiers.md` in the `containerization` fork

Existing upstream context:

- No open `apple/container` or `apple/containerization` issue or pull request was found for process listing or `top` support on 2026-06-22.

## Proposed behavior

- Accept `container compose top [SERVICES...]`.
- Resolve selected services to Compose-managed service containers, including discovered replicas and custom `container_name` values.
- Call `ContainerClient.processes(id:)` through a direct API adapter.
- Emit a service-aware PID-only table.
- Keep full Docker `top` process columns as a runtime metadata follow-up.

## Minimal example

```sh
container compose top api worker
```

Expected behavior:

- The plugin lists process identifiers for each selected service container on fork-backed branches.
- Branches pinned to released upstream `apple/container` continue to treat `top` as runtime-gated until an equivalent API lands upstream.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
