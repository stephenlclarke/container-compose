# Pull Request: accept completed dependency exit status

## Summary

- Accept the macOS runtime's `exited` lifecycle state for
  `service_completed_successfully`, alongside the existing `stopped` state.
- Keep the existing stored-exit-code and live-wait paths unchanged.
- Add unit regression coverage and prove the real one-shot dependency flow
  through Docker Compose V2 image-volume parity.

## Intended review delta

Apply signed commit
[`74d02bbdcc6d950cacd31868ae09503fc9d9aff9`](https://github.com/stephenlclarke/container-compose/commit/74d02bbdcc6d950cacd31868ae09503fc9d9aff9),
`fix(deps): accept completed service exit status`.

The change is deliberately limited to the Compose lifecycle adapter. It
preserves the generic `container` state model, does not add a macOS runtime
API, and includes no Windows or Linux-only branch. See the companion
[issue handoff](ISSUE-completed-dependency-exited-status.md).

## Code map

- `ComposeOrchestratorWaitAndPorts.completedDependencyExitCode` treats
  `stopped` and `exited` as completed states only when an exit code exists.
- `ComposeOrchestratorTests.upAcceptsExitedServiceCompletedDependencies`
  asserts a successful exited job starts its dependent without a second wait.
- `Tools/parity/check-compose-image-volumes.sh` already exercises the live
  `subpath-preparer` one-shot dependency and its dependent service.

## Validation

```console
swift test --disable-automatic-resolution \
  --filter ComposeCoreTests.ComposeOrchestratorTests/upAcceptsExitedServiceCompletedDependencies
swift test --disable-automatic-resolution --filter ComposeCoreTests
CONTAINER_RUNTIME_STOP_HELPER=/absolute/path/to/container/scripts/ensure-container-stopped.sh \
CONTAINER_RUNTIME_APP_ROOT=/private/tmp/container-compose-runtime \
CONTAINER_RUNTIME_INIT_BLOCK_REPO=/absolute/path/to/container \
CONTAINERIZATION_INIT_SOURCE_PATH=/absolute/path/to/containerization \
./scripts/run-with-container-runtime.sh /absolute/path/to/container/bin/container \
  make --no-print-directory -j1 CONTAINER_COMPOSE_LIVE=1 \
  CONTAINER_COMPOSE_CONTAINER=/absolute/path/to/container/bin/container \
  docker-compose-image-volumes-parity
```

The focused regression passed. The ComposeCore suite passed 1,007 tests in
16 suites. The source-matched live parity target passed Docker Compose V2
local-volume, `volume.subpath`, and teardown assertions after the preparer
reported `Exited`.

## Compatibility and risks

- A nonzero exit code still blocks the dependent exactly as before.
- Live `running` and `stopping` dependencies still use the existing wait
  primitive.
- Unknown lifecycle states remain unsupported rather than being interpreted
  as successful completion.
