<!-- markdownlint-disable MD013 -->

# [Request]: Run configured health probes with stable status transitions

## Feature or enhancement request details

`apple/container` needs runtime-owned evaluation of configured container health probes and a stable current result through `ContainerSnapshot.health`. External orchestrators can then wait for readiness through the direct API instead of treating `.running` as healthy.

This request consolidates the current runtime behavior tracked by:

- [apple/container#1502](https://github.com/apple/container/issues/1502): health status request.
- [apple/container#1504](https://github.com/apple/container/pull/1504): `HealthStatus` and `ContainerSnapshot.health`.
- [apple/container#1918](https://github.com/apple/container/issues/1918): healthcheck execution and reporting.

Requested behavior:

- Set health to `.starting` when a configured container starts.
- Delay the first probe by the active start or normal interval.
- Use five seconds when `startIntervalInNanoseconds` is omitted or zero.
- Use the start interval only while status remains `starting` and the start period is active.
- Treat a successful probe as the end of start-period failure grace.
- Use Docker-compatible defaults for zero interval, timeout, and retry values.
- Treat exit code `0` as healthy and reset the failure streak.
- Mark the container unhealthy after the configured number of consecutive failures.
- Kill timed-out probes and count them as failures.
- Emit `health_status: healthy` and `health_status: unhealthy` only on transitions.
- Preserve current health through `ManagedContainer`, inspect JSON, list JSON, and the list table.
- Stop the monitor when the container stops, exits, or is deleted.
- Keep Compose dependency ordering and wait policy outside `apple/container`.

Probe output history and an on-demand healthcheck command are separate API and CLI surfaces. They are not needed for readiness consumers.

Related references:

- [Dockerfile `HEALTHCHECK`](https://docs.docker.com/reference/dockerfile/#healthcheck)
- [Docker Compose `healthcheck`](https://docs.docker.com/reference/compose-file/services/#healthcheck)
- [Docker Compose `depends_on`](https://docs.docker.com/reference/compose-file/services/#depends_on)

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
