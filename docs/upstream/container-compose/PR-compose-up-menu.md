# Implement attached `compose up --menu`

## Summary

This change implements the first Docker Compose-compatible `up --menu` path inside `container-compose`:

- Rewrites Docker optional boolean forms so `--menu=true` reaches the menu flag and `--menu=false`, `--menu=0`, or `--menu=no` reach a hidden explicit-disable flag.
- Enables the menu only for attached terminal output with non-plain progress, matching Docker's terminal-gated behavior and avoiding menu activation in scriptable dry-run or no-start paths.
- Validates explicit `--menu` and `COMPOSE_MENU=true` incompatibilities before terminal gating so non-interactive scripts do not silently drop requested menu semantics.
- Starts menu-enabled `up` service graphs detached, then follows attachable service logs through a Compose-owned menu controller.
- Handles `d` detach, `w` watch toggle through the existing watch engine, first `Ctrl+C` graceful stop, second `Ctrl+C` force stop, and Enter redraw.
- Keeps `up --menu` with exit-control options rejected until combined exit/menu semantics are implemented.
- Marks `--menu` supported in CLI help while documenting the remaining command-level `up` boundaries in `README.md` and `STATUS.md`.

## Rationale

The Apple runtime does not expose an interactive attach primitive, but `up --menu` does not need to reattach stdin to a running container. Docker Compose's helper menu owns the terminal, starts the graph in the background, follows service logs, and reacts to shortcut keys. Those responsibilities fit cleanly in `container-compose`, using existing container lifecycle, log-follow, and watch orchestration helpers.

## Verification

Run focused local validation:

```sh
swift test --filter 'ComposeUpMenuTests|normalizesUpMenuBooleanValueForms|upMenuOptionShowsSupportedInteractiveShortcutHelp|upMenuFalseValueParsesThroughDockerComposeRewriter|runtimeDryRunUpAcceptsMenuBooleanValuesInNoStartMode|runtimeDryRunUpRejectsMenuIncompatibilitiesBeforeComposeSideEffects|upMenuFollowsAttachableSelectedServiceLogsThroughMenuController|upMenuDryRunEmitsLogFollowPlanWithoutInvokingMenuController|upMenuRejectsExitControlOptionsBeforeSideEffects|upMenuShortcutActionsStopAndKillSelectedServiceGraph|dependencyGroupsPreserveIndividuallyConfiguredCollaborators'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 COMPOSE_TEST_BINARY="$PWD/.build/debug/compose" swift test --skip-build --filter 'runtimeDryRunUpAcceptsMenuBooleanValuesInNoStartMode|runtimeDryRunUpRejectsMenuIncompatibilitiesBeforeComposeSideEffects'
```

Before release promotion, run the broader local gate:

```sh
make check
swift test --disable-automatic-resolution
make cli-smoke-built
make docker-compose-up-menu-parity
make coverage-check
git diff --check
```

## Compatibility Notes

- Docker Desktop-only `v`, `o`, and `l` shortcuts are intentionally absent because they target Docker Desktop UI surfaces.
- `up --menu` remains incompatible with `--abort-on-container-exit`, `--abort-on-container-failure`, and `--exit-code-from`.
- `up --menu` and `up --watch` remain separate modes until their combined behavior gets a dedicated Docker parity pass.
- Docker Compose 5.2.0 accepts the exit-control and watch combinations in dry-run mode; `make docker-compose-up-menu-parity` treats those as documented differences while requiring parity for the supported optional-boolean menu forms.
