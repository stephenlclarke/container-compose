# Report `compose watch` as Supported

## Summary

This change updates the CLI support matrix so `container compose watch` reflects the behavior already implemented in the watch engine:

- Marks `watch` as supported in `container compose help`.
- Adds focused help coverage for the `watch` command and its exposed options.
- Updates `STATUS.md` with the current `stephenlclarke/container` pin and the supported watch handoff.
- Adds this upstream handoff pair for review context.

## Rationale

The command was still advertised as partially supported even though the code path now covers the exposed Compose watch command surface. Keeping the help marker partial makes users look for a missing runtime gap that no longer applies to the command itself.

The remaining attached `up` log-presentation flags stay partial; this slice only updates the standalone `watch` command and its supported options.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'watchAppliesProvidedInitialUpOptions|watchDryRunEmitsValidatedTriggerPlan|watchRebuildsServicesAndPrunesImages|watchRejectsServicesWithoutDevelopTriggers|watchCommandAndOptionsAreShownAsSupported'
swift test --disable-automatic-resolution --filter ComposeCLIHelpTests
markdownlint STATUS.md docs/upstream/container-compose/ISSUE-compose-watch-support-status.md docs/upstream/container-compose/PR-compose-watch-support-status.md
git diff --check
```

Before release promotion, run the usual broader local gate:

```sh
make coverage-check
```

## Follow-Ups

- Attached `compose up` log-presentation flags are handled by the raw-output and timestamp slices; this watch slice does not change `up --attach`, `--attach-dependencies`, or exit-control behavior.
- If native filesystem events replace the current polling loop, track that as a separate implementation improvement rather than a support-status blocker.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `295c3a2cdecff35ee88c7c899157d88d659fb351`.
