# Support `compose up --timestamps`

## Summary

This change implements timestamped attached `compose up` output:

- Stops rejecting `up --timestamps` in attached mode.
- Marks `--timestamps` supported in `container compose help up`.
- Starts the service that would normally own foreground output in detached mode when timestamps are requested.
- Follows that service through `compose-runtime logs --follow --timestamps`.
- Preserves `--no-log-prefix` and ANSI color policy through the existing Compose log emitter.
- Adds focused unit coverage and a temp Dockerfile/compose dry-run smoke.

## Rationale

The default attached `up` behavior keeps direct terminal handoff for the foreground service. That remains the least surprising behavior for shells and process output. Timestamped output is different because Compose must own the byte stream to render timestamped runtime records. Starting the selected output service detached and following structured logs gives `--timestamps` a real implementation without changing ordinary attached `up`.

Detached, `--wait`, and `--no-start` modes already accepted log-presentation flags as harmless no-ops because those modes do not format attached output. This change targets only attached timestamped output.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'upTimestampsDetachesForegroundServiceAndFollowsTimestampedLogs|upTimestampsDryRunRendersDetachedRunAndFollowedTimestampedLogs|upTimestampsIsShownAsSupported|upRawAttachedOutputFlagsParse'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeDryRunUpTimestampsFollowsTimestampedLogs
npx --yes markdownlint-cli docs/upstream/container-compose/ISSUE-compose-up-timestamps.md docs/upstream/container-compose/PR-compose-up-timestamps.md
git diff --check
```

Before release promotion, run the usual broader local gate:

```sh
make coverage-check
make cli-smoke-built
```

## Compatibility Notes

- `compose up --timestamps` now follows logs instead of inheriting foreground process I/O, so stdin is not attached in this mode.
- The regular attached `compose up` path is unchanged when `--timestamps` is absent.
- This slice did not implement `up --attach`, `--attach-dependencies`, exit-control flags, or `--menu`; later follow-up slices cover those surfaces with their own compatibility notes.
