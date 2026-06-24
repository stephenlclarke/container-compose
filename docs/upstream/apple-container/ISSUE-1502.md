<!-- markdownlint-disable MD013 -->

# [Request]: Reserve HealthStatus enum and health field on ContainerSnapshot

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/02-feature.yml`.

## Feature or enhancement request details

External orchestrators that drive the `apple/container` API need to distinguish a started container from a healthy container. Docker Compose exposes this distinction through `depends_on.condition: service_healthy`, where a dependent service must not start until the dependency's healthcheck has reported success.

Today `ContainerSnapshot` exposes runtime status such as `.running`, but it does not expose a stable health shape. Consumers therefore have to treat liveness as health, sleep for a fixed interval, or maintain plugin-local state outside the runtime API. That is fragile for databases, queue brokers, and application services that accept processes before they are actually ready.

The requested first step is the narrow API shape proposed by Chris George in [apple/container#1504](https://github.com/apple/container/pull/1504):

- Add a public `HealthStatus` enum with `none`, `starting`, `healthy`, and `unhealthy`.
- Add optional `ContainerSnapshot.health: HealthStatus?`.
- Keep the field `nil` until a later runtime observer PR wires actual healthcheck execution and state updates.
- Preserve Codable wire compatibility by making the field optional.

This is intentionally data-shape only. The runtime healthcheck observer should be reviewed separately because it needs decisions about healthcheck configuration, probe execution, cadence, retries, start periods, exit-code interpretation, and sandbox/API-server boundaries.

Related context:

- [apple/container#1502](https://github.com/apple/container/issues/1502): existing feature issue for the data shape.
- [apple/container#1504](https://github.com/apple/container/pull/1504): Chris George's draft data-shape PR.
- [Docker Compose `depends_on`](https://docs.docker.com/reference/compose-file/services/#depends_on): documents `condition: service_healthy`.
- [Dockerfile `HEALTHCHECK`](https://docs.docker.com/reference/dockerfile/#healthcheck): documents container health probe configuration.
- `container-compose` needs this field before it can implement `depends_on.condition: service_healthy` through direct `ContainerClient` APIs instead of polling CLI output or inventing plugin-local health state.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
