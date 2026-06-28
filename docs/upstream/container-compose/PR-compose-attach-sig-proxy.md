# Support `compose attach --no-stdin` Signal Proxying

## Summary

This change tightens the supported `compose attach` subset:

- Accepts default `attach --no-stdin` without requiring `--sig-proxy=false`.
- Marks `attach --sig-proxy` as supported in CLI help.
- Adds a small signal-proxy collaborator for deterministic testing and live signal handling.
- Forwards `SIGHUP`, `SIGINT`, `SIGQUIT`, and `SIGTERM` to the selected service container through the direct lifecycle API while the log-follow attach path is active.
- Keeps `--sig-proxy=false` as an opt-out that follows logs without forwarding signals.
- Keeps stdin reattach and `--detach-keys` rejected with explicit runtime-gap messages.

## Rationale

The current `attach` implementation is intentionally output-only because apple/container does not expose an interactive reattach primitive for an already-running container. That output-only mode can still support Docker Compose's default signal proxy behavior by installing host signal handlers while following logs and forwarding received signals through the existing direct `killContainer(id:signal:)` lifecycle surface.

This keeps the change local to `container-compose` and avoids pretending that stdin or detach-key handling exists. The command remains partially supported until interactive attach is available, but the supported `--no-stdin` path now works with Docker Compose's default `--sig-proxy=true`.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'attachOutputOnlyModeFollowsDirectLogs|attachOutputOnlyModeProxiesReceivedSignalsByDefault|attachOutputOnlyModeSkipsSignalProxyWhenDisabled|attachReportsAppleContainerRuntimeGapForInteractiveOptions|attachSignalProxyOptionIsShownAsSupported|attachSignalProxyFlagParses'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeDryRunAttachNoStdinFollowsLogsWithDefaultSignalProxy
git diff --check
```

Before release promotion, run the broader local gate:

```sh
make check
make cli-smoke-built
make coverage-check
```

## Compatibility Notes

- `attach --no-stdin` now accepts the Docker Compose default signal-proxy setting.
- Signal forwarding is scoped to the selected service container replica.
- The supported signal set is the common process-control set available through macOS dispatch signal sources: `SIGHUP`, `SIGINT`, `SIGQUIT`, and `SIGTERM`.
- `--detach-keys` remains unsupported because there is no interactive attach session to detach from.
- Plain `attach SERVICE` remains unsupported because stdin/stdout/stderr reattach for already-running service containers still needs an apple/container runtime primitive.
