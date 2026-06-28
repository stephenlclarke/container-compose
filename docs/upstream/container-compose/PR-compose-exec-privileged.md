# Support Privileged Compose Exec

## Summary

This change wires the newly available privileged process exec primitive into `container-compose`:

- Marks `compose exec` supported in CLI help.
- Marks `exec --privileged` supported in CLI help.
- Passes `privileged` through attached and detached service exec requests.
- Passes `privileged` through lifecycle hook and `develop.watch sync+exec` direct exec requests.
- Renders `--privileged` in dry-run `container exec` output.
- Adds focused unit coverage and a compose.yml/Dockerfile-backed runtime dry-run smoke test.

## Rationale

Before this slice, `container-compose` rejected `exec --privileged` because upstream `apple/container` had no process-level privileged exec field. The local `stephenlclarke/container` fork now carries that generic runtime primitive, so the Compose plugin can stop treating this as a missing runtime gap.

The implementation keeps Docker Compose policy in the plugin. The sibling `container` fork only receives the typed process configuration field, CLI parser flag, and runtime capability mapping.

## Commit Tracking

- Required `container` fork commit: `39a2ce4ccb6c474d41a6146a6148d445b7fa0554` (`feat(exec): support privileged processes`).
- Container-compose integration commit: `91794a69da897ffe548165e435eaff828271c775` (`feat(exec): support privileged compose exec`).

## Implementation Details

- Added `privileged` to `ContainerAttachedExecRequest` and `ContainerDetachedExecRequest`.
- Set `ProcessConfiguration.privileged` in `ContainerClientExecManager`.
- Removed stale unsupported validation for `compose exec --privileged`.
- Removed stale unsupported validation for lifecycle hook and `develop.watch sync+exec` `privileged: true`.
- Added `--privileged` to dry-run command rendering.
- Promoted `exec` and `exec --privileged` support metadata to supported.
- Kept service-level `privileged: true` unsupported because it is a separate container-create-time feature.

## Verification

Focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'execMapsPrivilegedModeToRuntimeRequests|execMapsEnvironmentUserWorkdirAndDetachOptions|execDryRunRendersDetachedRuntimeCommand|upDetachedRunsPostStartHooksThroughDirectExec|watchSyncsChangedFilesAndRunsSyncExecHooks|detachedExecManagerMapsRequestToDirectProcessAPI|attachedExecManagerMapsRequestToDirectProcessAPI|execCommandAndPrivilegedOptionAreShownAsSupported'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeDryRunExecRendersPrivilegedCommand
```

Before release promotion, run the usual broader local gate:

```sh
make coverage-check
markdownlint STATUS.md docs/upstream/apple-container/ISSUE-exec-privileged.md docs/upstream/apple-container/PR-exec-privileged.md docs/upstream/container-compose/ISSUE-compose-exec-privileged.md docs/upstream/container-compose/PR-compose-exec-privileged.md
git diff --check
```

## Follow-Ups

- Keep service-level `privileged: true` unsupported until the service container create path has a reviewed runtime mapping for the broader isolation changes.
- Keep `compose attach` partial until interactive attach and signal proxy behavior has a runtime-backed implementation.
