# Pull Request: Preserve `up --exit-code-from` service status

## Summary

- Makes foreground `container compose up --exit-code-from SERVICE` return the selected service's terminal status after cleanup.
- Prevents teardown-closing an attached log stream from replacing that status with a generic orchestration failure.
- Marks `--exit-code-from` as supported in generated Compose help and the current parity ledger.
- Adds a regression test, live runtime smoke assertion, checked-in Compose fixture, and Docker Compose V2 parity target.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose V2 returns the selected container's status from `up --exit-code-from`. The Compose implementation had all lifecycle primitives needed to do this, but its throwing task-group race allowed a normal log-stream interruption during `down` to win over the selected container result. A selected `api` service exiting `7` consequently produced status `5`.

The defect is Compose-owned: the matched Apple runtime already exposes container wait, stop, delete, and log-follow operations. Keeping the correction in `container-compose` avoids an invasive fork change and leaves the Apple upstream surface unchanged.

## Implementation Details

- `Sources/ComposeCore/ComposeOrchestratorUpLogs.swift` now owns the exit-control lifecycle result separately from the output-only log task. It waits for exit control, then cancels and drains the log task without allowing teardown interruption to override the lifecycle status.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` adds the regression where the log follower ends before the selected status becomes available.
- `Tests/ComposeRuntimeTests/ComposeRuntimeSmokeTests.swift` now requires the real matched runtime CLI path to return `7`.
- `Sources/ComposePlugin/ComposeCLIHelp.swift` and `STATUS.md` mark `--exit-code-from` supported and remove the resolved limitation while retaining the independent `pre_start` and container-facing DNS gaps on `up`.
- `Tools/parity/fixtures/up-exit-code-from/compose.yaml` and `Tools/parity/check-compose-up-exit-code-from.sh` compare Docker Compose V2's exit-7 contract and run the same fixture against a matching Apple runtime when `CONTAINER_COMPOSE_LIVE=1`.
- `Makefile` and `BUILD.md` register `make docker-compose-up-exit-code-from-parity` in the lifecycle validation lane.

## Docker Compose Compatibility

The checked-in fixture has an `api` service that exits `7` and a `db` dependency that remains active. Docker Compose V2 returns `7` for `up --exit-code-from api api`; the matched Apple runtime lane must return the same status. The plugin retains its existing cleanup behavior after the exit condition, while the public status contract is the Docker Compose-selected terminal status.

## Validation

```console
swift test --disable-automatic-resolution --filter \
  'upExitCodeFrom(ReturnsSelectedServiceStatusAndTearsDownProject|AbortsOnOtherServiceExitAndReturnsSelectedStatus|PreservesSelectedStatusWhenAttachedLogFollowEnds)' --no-parallel
swift test --disable-automatic-resolution --filter ComposeCLIHelpTests --no-parallel
make docker-compose-up-exit-code-from-parity
bash -n Tools/parity/check-compose-up-exit-code-from.sh
shellcheck Tools/parity/check-compose-up-exit-code-from.sh
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 \
swift test --disable-automatic-resolution --skip-build \
  --filter ComposeRuntimeTests.ComposeRuntimeSmokeTests/\
runtimeUpExitCodeFromReturnsSelectedServiceStatus --no-parallel
```

The final command is intentionally part of the matching-runtime release gate; it cannot be truthfully substituted with an older locally installed Apple runtime that has a different API schema.

## Compatibility and Risks

- No Compose-file behavior, command syntax, or Apple API changes are introduced.
- `--exit-code-from` remains incompatible with modes that release or remove lifecycle control, such as `--detach`, `--wait`, `--no-start`, and `--watch`.
- The log task remains observable output only while exit control is active. Lifecycle errors still fail the command; only log-stream termination during that controlled lifecycle path cannot replace the selected status.

## Commit and Handoff Tracking

- Primary signed implementation: `fix(up): preserve exit-code-from status` in `stephenlclarke/container-compose`.
- Source handoff: `Sources/ComposeCore/ComposeOrchestratorUpLogs.swift` and its regression coverage in `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift`.
- No `apple/container`, `containerization`, or other fork commit is needed. The change is deliberately Compose-only and suitable for upstream review as an Apple-shaped minimal integration correction.
