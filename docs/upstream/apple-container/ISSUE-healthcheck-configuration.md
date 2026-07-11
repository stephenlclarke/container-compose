<!-- markdownlint-disable MD013 -->

# [Request]: Add a container healthcheck configuration model

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/02-feature.yml`.

## Feature or enhancement request details

`apple/container` now has a proposed `ContainerSnapshot.health` shape in [apple/container#1504](https://github.com/apple/container/pull/1504), but the runtime also needs a place to store the probe definition that will eventually populate that field. Docker and Docker Compose both model container healthchecks as a process plus timing policy: interval, timeout, start period, optional start interval, and retry count.

The requested slice is intentionally only the configuration model:

- Add `ContainerHealthCheck`.
- Store it as optional `ContainerConfiguration.healthCheck`.
- Represent the probe itself as a normal `ProcessConfiguration`.
- Represent Docker-compatible timing values as nanoseconds so callers do not lose sub-second Compose/Dockerfile values.
- Keep runtime execution as a separate follow-up PR.

Per JLogan's guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), Docker/Compose `healthcheck` parsing and Docker-shaped `--health-*` flags should stay in `container-compose`. The Apple-facing ask is the typed `ContainerHealthCheck` configuration model.

Keeping this shape separate lets maintainers review the public API and wire format before discussing the background healthcheck observer.

Related context:

- [apple/container#1502](https://github.com/apple/container/issues/1502): health status data-shape request.
- [apple/container#1504](https://github.com/apple/container/pull/1504): draft `HealthStatus` and `ContainerSnapshot.health` shape.
- [Dockerfile `HEALTHCHECK`](https://docs.docker.com/reference/dockerfile/#healthcheck): documents healthcheck command and timing fields.
- [Docker Compose `healthcheck`](https://docs.docker.com/reference/compose-file/services/#healthcheck): documents Compose healthcheck override fields.
- [Docker Compose `depends_on`](https://docs.docker.com/reference/compose-file/services/#depends_on): documents `condition: service_healthy`.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
