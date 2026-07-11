# Support `compose up` Attach Log Selection

## Summary

This change fills another `compose up` partial-support gap:

- Stops rejecting `--attach` and `--attach-dependencies`.
- Marks both options as supported in help.
- Adds `ComposeUpOptions.attach` and `attachDependencies`.
- Starts services detached when positive attach selectors are used, then follows selected service logs through the existing multi-target runtime log follower.
- Expands `--attach-dependencies` through the selected dependency graph.
- Validates unknown attach services and services outside the selected start graph before runtime side effects.

## Rationale

The existing foreground `up` path can only hand terminal ownership to one container process. Positive attach selectors are log-stream selection features, so they are better represented by the Compose-owned log-follow path already used by `compose logs --follow` and `up --timestamps`.

That keeps the change local to `container-compose`: service creation remains unchanged, selected services are started detached for attach-log mode, and log output is multiplexed by the existing direct log manager.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'upAttachFollowsSelectedServiceLogsAfterDetachedStart|upAttachDependenciesFollowsSelectedServiceAndDependencyLogs|upAttachRejectsServicesOutsideSelectedStartGraph|upAttachOptionsAreShownAsSupported|upRawAttachedOutputFlagsParse'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeDryRunUpAttachFollowsSelectedLogs
git diff --check
```

Before release promotion, run the broader local gate:

```sh
make check
make cli-smoke-built
make coverage-check
```

## Compatibility Notes

- `up --attach` only follows services that are part of the selected start graph. Selecting an unrelated service is rejected before side effects.
- `up --attach-dependencies` does not override `--no-deps`; dependencies that are not started are not followed.
- Exit-control options such as `--exit-code-from`, `--abort-on-container-exit`, and `--abort-on-container-failure` remain separate partial-support items.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `b837f1bba4f909ae31e8b9d47c460c98cf717abb`.
