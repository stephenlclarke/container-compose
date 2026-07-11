<!-- markdownlint-disable MD013 -->

# feat(api): model container healthcheck configuration

## Template

This PR draft follows `.github/pull_request_template.md`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This is the second small health slice after [apple/container#1504](https://github.com/apple/container/pull/1504). It reserves the container healthcheck configuration shape that a later observer will execute and use to populate `ContainerSnapshot.health`.

The shape is intentionally generic and not Compose-specific. Compose parsing or image metadata can normalize their source fields into the same `ContainerHealthCheck` model before the container is created. Following JLogan's guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), Docker-shaped `--health-*` parser compatibility stays in `container-compose` unless Apple maintainers explicitly want a native command convenience.

## What Changed

- Adds `ContainerHealthCheck` to `ContainerResource`.
- Adds optional `ContainerConfiguration.healthCheck`.
- Uses `ProcessConfiguration` for the probe process.
- Stores interval, timeout, start period, optional start interval, and retries.
- Adds `ContainerConfigurationHealthCheckTests` for round-trip and backward-compatible decode behavior.

## Commit Tracking

- Container code commit: `f41c817` in `stephenlclarke/container` (`feat(api): model container health checks`).
- Lower runtime code commit: not required.
- Compose mapping code is not part of this Apple PR.

## Non-Goals

- This does not execute health probes.
- This does not parse Dockerfile `HEALTHCHECK` metadata from image config.
- This does not add CLI flags.
- This does not implement Compose `depends_on.condition: service_healthy`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Local verification:

```bash
swift test --filter ContainerConfigurationHealthCheckTests
```

Result:

- `ContainerConfigurationHealthCheckTests`: 2 passing tests.

New or relevant coverage:

- Healthcheck process and timing fields round-trip through `ContainerConfiguration` JSON.
- Older container configuration JSON without `healthCheck` decodes with `nil`.

## Compatibility Notes

Adding `healthCheck` as an optional `ContainerConfiguration` field is backward compatible with persisted container configs. Older configs decode with `nil`, and existing callers that do not set healthchecks keep the same runtime behavior.

Timing is stored in nanoseconds to preserve Docker and Compose duration precision. The observer follow-up can translate those values into `Duration` when scheduling probes.

## Remaining Risks

- Maintainers may prefer a different field name or a future image-config inheritance model.
- The runtime observer still needs its own review for process execution, timeout handling, retry semantics, start-period behavior, and cancellation when containers stop.
