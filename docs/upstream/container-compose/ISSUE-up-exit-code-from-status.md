# Issue handoff: `up --exit-code-from` lost the selected service status

## Status

Resolved in the Compose layer by the `fix(up): preserve exit-code-from status` slice. No Apple runtime or fork change is required.

## Problem

The foreground `container compose up --exit-code-from SERVICE` path starts the selected graph detached, waits for the selected container, and then tears the project down. A live macOS guest run with an `api` service exiting with `7` incorrectly returned generic orchestration status `5`.

Docker Compose V2 returns the selected service status for `up --exit-code-from api api`. This command must continue to return `7` even though cleanup naturally closes the foreground log streams.

## Root Cause

`runUpLogOperationUntilExitControl` raced log following against the exit-control lifecycle operation in one throwing task group. The lifecycle operation performs `down` before returning the selected status. Closing a followed log stream during that teardown could therefore throw before the lifecycle task published its result, causing the plugin to surface a generic command failure instead of the selected service status.

## Scope and Ownership

This was Phase 4 lifecycle/status-propagation work in `container-compose`. The matched runtime can start, wait for, stop, and delete the selected container; no missing Apple primitive was involved. The correction remains in the Compose orchestration layer, preserving an Apple-shaped upstream boundary.

## Resolution

- Treat exit control as the authoritative owner of the command result.
- Keep the attached log follower for output only while exit control is active.
- Cancel and await the log task after the lifecycle operation completes, deliberately ignoring a teardown-induced log-stream error.
- Continue to surface a real lifecycle error if exit control itself fails.

## Verification

The regression fixture uses an `api` service that exits with `7` beside a `db` dependency that remains running.

```console
swift test --disable-automatic-resolution --filter \
  'upExitCodeFrom(ReturnsSelectedServiceStatusAndTearsDownProject|AbortsOnOtherServiceExitAndReturnsSelectedStatus|PreservesSelectedStatusWhenAttachedLogFollowEnds)' --no-parallel
make docker-compose-up-exit-code-from-parity
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 \
swift test --disable-automatic-resolution --skip-build \
  --filter ComposeRuntimeTests.ComposeRuntimeSmokeTests/\
runtimeUpExitCodeFromReturnsSelectedServiceStatus --no-parallel
```

The Docker Compose V2 parity target verifies the reference exits `7` and validates the same checked-in Compose fixture and status on the isolated matching Apple runtime during the hosted release gate.
