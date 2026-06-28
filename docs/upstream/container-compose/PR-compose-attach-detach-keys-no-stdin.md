# Accept `compose attach --no-stdin --detach-keys`

## Summary

This change accepts `compose attach --no-stdin --detach-keys=...` on the supported output-only attach path:

- Treats detach-key settings as no-op metadata when stdin is disabled.
- Keeps `attach --detach-keys=... SERVICE` blocked with the existing interactive attach runtime-gap error.
- Marks `attach --detach-keys` as partially supported in CLI help and documents the no-op behavior with `--no-stdin`.
- Adds focused orchestrator, parser/help, runtime dry-run, and Makefile smoke coverage.

## Rationale

The current attach implementation streams service output through the runtime log API when `--no-stdin` is set. In that mode there is no interactive stdin stream to detach from, so a configured detach-key sequence has no runtime effect.

Rejecting `--detach-keys` before checking the selected attach mode makes otherwise valid Docker Compose invocations fail even though the plugin can safely perform the requested output-only operation.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'attachOutputOnlyModeIgnoresDetachKeys|attachReportsAppleContainerRuntimeGapForInteractiveOptions|attachSignalProxyOptionIsShownAsSupported|attachSignalProxyFlagParses'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeDryRunAttachNoStdinFollowsLogsWithDefaultSignalProxy
git diff --check
```

Before pushing the main-only compatibility slice, run the broader local gate:

```sh
make check
make cli-smoke-built
```

## Compatibility Notes

- `--detach-keys` is accepted only when `--no-stdin` selects output-only attach.
- Interactive attach remains unsupported until apple/container exposes reattach and detach-key primitives.
- The command remains partially supported.
