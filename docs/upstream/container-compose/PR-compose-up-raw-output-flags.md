# Support `compose up --no-color` and `--no-log-prefix`

## Summary

This change updates attached `compose up` log-presentation flag handling:

- Stops rejecting `up --no-color` in attached mode.
- Stops rejecting `up --no-log-prefix` in attached mode.
- Marks both options supported in `container compose help up`.
- Adds focused parser/help coverage.
- Timestamped attached `up` output is covered by the follow-up `PR-compose-up-timestamps.md` slice.

## Rationale

The attached `up` path already emits raw foreground process output and does not add Compose-owned colors or service prefixes. Rejecting `--no-color` and `--no-log-prefix` therefore prevented Docker Compose-compatible invocations even though the requested output shape was already the current output shape.

`--timestamps` was implemented separately because satisfying it requires timestamped runtime log records, not raw foreground process bytes.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'upRawAttachedOutputFlagsAreShownAsSupported|upRawAttachedOutputFlagsParse'
swift test --disable-automatic-resolution --filter ComposeCLIHelpTests
markdownlint STATUS.md docs/upstream/container-compose/ISSUE-compose-up-raw-output-flags.md docs/upstream/container-compose/PR-compose-up-raw-output-flags.md
git diff --check
```

Before release promotion, run the usual broader local gate:

```sh
make coverage-check
```

## Follow-Ups

- This slice deliberately left `up --attach`, `--attach-dependencies`, exit-control flags, and `--menu` to later process-control slices.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `1233b45dd58a622b8bb23b057b7a980dbd560928`.
