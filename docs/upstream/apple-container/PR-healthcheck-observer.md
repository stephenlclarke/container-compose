<!-- markdownlint-disable MD013 -->

# fix(health): align probe scheduling and status reporting

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This is the complete generic runtime observer for [apple/container#1918](https://github.com/apple/container/issues/1918). It builds on the health status shape from [apple/container#1504](https://github.com/apple/container/pull/1504) and the typed `ContainerHealthCheck` configuration.

Readiness consumers need more than a running state. The observer executes configured probes, applies stable scheduling and retry semantics, publishes transitions, and preserves current health through API and CLI projections. Compose policy remains outside `apple/container`.

## What Changed

- Starts a monitor when a container with `configuration.healthCheck` starts.
- Delays the first probe by the applicable interval.
- Uses Docker-compatible normal, start, timeout, and retry defaults when values are omitted or zero.
- Uses the start interval only while the container is still starting inside its start period.
- Ends start-period failure grace after the first successful probe.
- Resets consecutive failures on success and marks unhealthy at the retry threshold.
- Cancels timed-out probes and monitors for stopped, exited, or deleted containers.
- Emits `health_status` events only when status changes and includes health in event attributes.
- Preserves health in `ManagedContainer`, inspect JSON, list JSON, and the list table.

## Commit Tracking

- Current observer correction: `9c83559` in `stephenlclarke/container` (`fix(health): align probe scheduling and status reporting`).
- Observer foundation: `fa97154` (`feat(api): observe container health checks`).
- Configuration model: `f41c817` (`feat(api): model container health checks`).
- Status model: `d995767` (`feat(api): reserve container health status`).
- Lower runtime code: not required.
- Compose readiness behavior is documented in `docs/upstream/container-compose/PR-compose-health-aware-wait.md`.

## Compatibility Notes

The wire shape remains additive. Containers without a healthcheck omit health, and older persisted `ManagedContainer` JSON without health decodes with `nil`.

Probe cadence changes intentionally: configurations that previously ran an immediate first probe now wait for the applicable interval, and zero retries use the default threshold instead of becoming unhealthy after one failure.

## Testing

```bash
swift test --filter 'ContainerHealthMonitorTests|ManagedContainerTests|ManagedContainerDisplayTests' --no-parallel
make check
make test
make integration
```

Validation completed with 18 focused health tests, 902 Swift Testing tests, 94 XCTest tests, 214 concurrent integration tests, and 142 serial integration tests passing.

## Remaining Scope

- Probe output history and failing-streak details are not exposed as a public snapshot object.
- An on-demand healthcheck command remains separate work under `apple/container#1918`.
