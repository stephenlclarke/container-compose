# Support `compose up` Exit Control

## Summary

This change fills another `compose up` partial-support gap:

- Stops rejecting `--exit-code-from`, `--abort-on-container-exit`, and `--abort-on-container-failure`.
- Marks those options as supported in help.
- Adds exit-control fields to `ComposeUpOptions`.
- Starts services detached when exit-control mode is active, then waits through the direct lifecycle API.
- Tears the project down through the normal `down` path after the exit condition is met.
- Propagates the selected or failing container exit status from the plugin process.
- Rejects incompatible `--detach`, `--wait`, `--no-start`, and `--watch` combinations before runtime side effects.

## Rationale

Exit-control mode needs `container-compose` to retain control of the service containers after startup. Reusing the existing foreground process handoff would attach the terminal to one container and leave no Compose-owned place to wait for other services, tear the project down, or return a selected service's exit status.

Starting the selected graph detached keeps this change local to `container-compose`: service creation remains unchanged, lifecycle waits go through the direct runtime adapter, and cleanup uses the existing `compose down` orchestration.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'upExitCodeFromReturnsSelectedServiceStatusAndTearsDownProject|upExitCodeFromAbortsOnOtherServiceExitAndReturnsSelectedStatus|upAbortOnContainerFailureReturnsFailingStatusAndTearsDownProject|upAbortOnContainerExitReturnsFirstStatusAndTearsDownProject|upExitControlDryRunRendersWaitThenDownPlan|upExitControlRejectsDetachedModeBeforeSideEffects|upExitControlOptionsAreShownAsSupported|upRawAttachedOutputFlagsParse'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeUpExitCodeFromReturnsSelectedStatus
git diff --check
```

Before release promotion, run the broader local gate:

```sh
make check
make cli-smoke-built
make coverage-check
```

## Compatibility Notes

- `up --exit-code-from SERVICE` requires the selected service to be part of the selected start graph.
- Exit-control options are incompatible with `--detach`, `--wait`, and `--no-start` because those modes either release process control or do not start containers.
- `up --watch` remains a separate watch-engine mode and rejects exit-control combinations.
- `up --menu` can now be combined with exit-control options; the menu follows logs while the existing exit-control waiter decides teardown and process status.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `8939458ce580943f07f4542f6e3eb42596fdf88c`.
