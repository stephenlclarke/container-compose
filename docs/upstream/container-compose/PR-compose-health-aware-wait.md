# Implement health-aware Compose lifecycle waits

## Summary

- Make `condition: service_healthy` consume stable runtime health state.
- Make `up --wait` and `start --wait` wait for configured healthchecks.
- Fail immediately when a selected container becomes unhealthy.
- Preserve health through CLI JSON discovery and `ps --format json`.
- Mark `up`, `--wait`, and `--wait-timeout` fully supported.
- Add Docker Compose v2 live parity coverage.

## Runtime Integration

The companion fork change implements the Compose-enabling portion of [apple/container#1918](https://github.com/apple/container/issues/1918): Docker-compatible first-probe delay, start-interval defaults, retry/start-period transitions, health events, and health in `ManagedContainer` output. Compose keeps all dependency selection and timeout policy in this repository.

Live discovery uses `container list --format json` for list and detail reads. This keeps the plugin on the stable process boundary while retaining health, exit metadata, mounts, ports, networks, and labels. `CONTAINER_COMPOSE_CONTAINER` and `CONTAINER_BIN` now select the same executable for compatibility preflight and runtime operations.

## Swift 6.3 Workaround

The live fixture exposed the task allocator crash tracked by [swiftlang/swift#81771](https://github.com/swiftlang/swift/issues/81771). Health polling isolates the large discovery value in a non-inlined async helper. The production default uses a cancellation-aware 250 ms blocking delay so no new async sleep frame is allocated after the read; injected test sleepers remain asynchronous and deterministic.

## Verification

```sh
swift test --filter 'upWaitPollsConfiguredHealthchecksUntilHealthy|upWaitFailsWhenConfiguredHealthcheckBecomesUnhealthy|upWaitTimeoutReportsUpCommand|startWaitPollsConfiguredHealthchecksUntilHealthy|upWaitOptionsShowFullHealthSupport|cliJSONDiscoveryManagerMapsContainerListOutputToComposeSummaries' --no-parallel
make docker-compose-health-wait-parity
make check
make cli-smoke-built
```

The live parity target verifies healthy `up --wait`, healthy `start --wait`, JSON health output, and unhealthy failure through both Docker Compose v2 and `container-compose`.

## Compatibility

Projects without healthchecks continue to wait for running state. Existing `ManagedContainer` JSON without a health field decodes with `nil`. The CLI support matrix now reports `up`, `--wait`, and `--wait-timeout` as supported.

## Project Checks

- [x] Added focused unit and live parity tests.
- [x] Updated current-state documentation and CLI support colors.
- [x] Kept the runtime change generic and linked to the original Apple issue.
- [x] Avoided pushes to Apple remotes.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `a357e261e471cf7bc453eedc308a3d39e201ba4d`.
