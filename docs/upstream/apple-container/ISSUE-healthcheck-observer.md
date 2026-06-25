<!-- markdownlint-disable MD013 -->

# [Request]: Run configured container health probes and publish health status

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/02-feature.yml`.

## Feature or enhancement request details

`apple/container` needs a runtime-owned way to evaluate configured container health probes and publish their current result through `ContainerSnapshot.health`. External orchestrators can then wait for healthy dependencies through the direct API instead of guessing that `.running` means ready.

This is the execution follow-up to the health data-shape and configuration slices:

- [apple/container#1502](https://github.com/apple/container/issues/1502): health status request.
- [apple/container#1504](https://github.com/apple/container/pull/1504): `HealthStatus` and `ContainerSnapshot.health`.
- `ISSUE-healthcheck-configuration.md`: local fork handoff for `ContainerHealthCheck` and `ContainerConfiguration.healthCheck`.

Requested behavior:

- When a container with `configuration.healthCheck` starts, set `ContainerSnapshot.health` to `.starting`.
- Periodically run the configured `ProcessConfiguration` inside the running container.
- Treat exit code `0` as healthy.
- Count non-zero exits as failures only after `startPeriodInNanoseconds`.
- Mark the container unhealthy after `retries` consecutive counted failures.
- Keep a previously healthy container healthy until the retry threshold is crossed.
- Kill timed-out probes and count them as failures.
- Stop the health monitor when the container stops, exits, or is deleted.
- Keep Compose dependency ordering outside `apple/container`.

Related Docker references:

- [Dockerfile `HEALTHCHECK`](https://docs.docker.com/reference/dockerfile/#healthcheck)
- [Docker Compose `healthcheck`](https://docs.docker.com/reference/compose-file/services/#healthcheck)
- [Docker Compose `depends_on`](https://docs.docker.com/reference/compose-file/services/#depends_on)

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
