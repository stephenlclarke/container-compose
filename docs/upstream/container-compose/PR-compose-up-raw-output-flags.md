# Support `compose up --no-color` and `--no-log-prefix`

## Summary

This change updates attached `compose up` log-presentation flag handling:

- Stops rejecting `up --no-color` in attached mode.
- Stops rejecting `up --no-log-prefix` in attached mode.
- Marks both options supported in `container compose help up`.
- Adds focused parser/help coverage.
- Leaves `up --timestamps` partial because attached foreground output still lacks structured runtime timestamps.

## Rationale

The attached `up` path already emits raw foreground process output and does not add Compose-owned colors or service prefixes. Rejecting `--no-color` and `--no-log-prefix` therefore prevented Docker Compose-compatible invocations even though the requested output shape was already the current output shape.

`--timestamps` remains different: satisfying it requires timestamped runtime log records, not raw foreground process bytes. Keeping that option partial avoids claiming a timestamp feature that is not implemented yet.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'upRawAttachedOutputFlagsAreShownAsSupported|upRawAttachedOutputFlagsParse|upTimestampsRemainsPartialUntilAttachedLogFollowingSupportsIt'
swift test --disable-automatic-resolution --filter ComposeCLIHelpTests
markdownlint STATUS.md docs/upstream/container-compose/ISSUE-compose-up-raw-output-flags.md docs/upstream/container-compose/PR-compose-up-raw-output-flags.md
git diff --check
```

Before release promotion, run the usual broader local gate:

```sh
make coverage-check
```

## Follow-Ups

- Implement timestamped attached `compose up` output by moving that mode to structured runtime log follow or another timestamp-aware output path.
- Keep `up --attach`, `--attach-dependencies`, `--exit-code-from`, `--abort-on-container-exit`, `--abort-on-container-failure`, and `--menu` unsupported until their process-control semantics are implemented.
