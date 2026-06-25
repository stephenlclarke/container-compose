<!-- markdownlint-disable MD013 -->

# feat(api): observe configured container health checks

## Template

This PR draft follows `.github/pull_request_template.md`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This is the runtime execution slice for container health status. It builds on the reserved `HealthStatus` / `ContainerSnapshot.health` shape from [apple/container#1504](https://github.com/apple/container/pull/1504) and the local `ContainerHealthCheck` configuration slice.

Docker Compose `depends_on.condition: service_healthy` requires a direct API signal that a running dependency has actually become ready. Polling `.running` is not enough for common local-development services such as databases and brokers.

## What Changed

- Starts a background health monitor when a container with `configuration.healthCheck` starts.
- Sets `ContainerSnapshot.health` to `.starting` while probes are pending.
- Executes the configured `ProcessConfiguration` through the existing runtime process APIs.
- Treats exit code `0` as `.healthy`.
- Counts non-zero exits and probe timeouts after the start period.
- Marks `.unhealthy` after the configured retry threshold.
- Cancels monitors when containers stop, exit, or are deleted.
- Adds pure state-machine tests for start-period and retry behavior.

## Commit Tracking

- Container code commit: `fa97154` in `stephenlclarke/container` (`feat(api): observe container health checks`).
- Container dependency commits:
  - `d995767` (`feat(api): reserve container health status`).
  - `f41c817` (`feat(api): model container health checks`).
- Lower runtime code commit: not required.
- Compose dependency mapping is not part of this Apple PR.

## Non-Goals

- This does not parse Dockerfile `HEALTHCHECK` metadata from image configs.
- This does not add CLI flags for healthchecks.
- This does not implement Compose `depends_on.condition: service_healthy`.
- This does not store Docker-style health probe output/history.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Local verification:

```bash
swift test --filter ContainerHealthMonitorTests
swift test --filter 'ContainerHealthMonitorTests|ContainerConfigurationHealthCheckTests|ContainerSnapshotTests'
git diff --check
```

Result:

- `ContainerHealthMonitorTests`: 5 passing tests.
- Combined focused API/config/status run: 11 passing tests.
- Whitespace checks passed locally.

New or relevant coverage:

- Failures during the start period do not count against retries.
- Counted failures transition to `.unhealthy` after the retry threshold.
- A previously healthy container remains healthy until the threshold is crossed.
- Successful probes reset the failure streak.
- Zero retries are clamped so the first counted failure becomes unhealthy.

## Compatibility Notes

Containers without `configuration.healthCheck` keep `health == nil` and existing runtime behavior. Containers with a healthcheck publish status only while running; stopped snapshots clear health to avoid stale readiness signals.

The observer uses the existing runtime process API, so no Compose-specific behavior enters `apple/container`. Dockerfile-inherited healthchecks remain a separate image-config parsing gap because the current `ContainerizationOCI.ImageConfig` type does not decode Docker's `Healthcheck` extension.

## Remaining Risks

- Maintainers may prefer health probe execution inside the runtime service rather than the API server owning the scheduling loop.
- Docker stores health probe output/history; this slice only publishes current status.
- Dockerfile `HEALTHCHECK` inheritance still needs a separate image config model change.
