# Report `compose run` as Supported

## Summary

This change updates the CLI support matrix so `container compose run` reflects the behavior already implemented in the one-off container engine:

- Marks `run` as supported in `container compose help`.
- Adds focused help coverage for the `run` command and representative exposed options.
- Updates `STATUS.md` with the current supported `run` handoff.
- Adds this upstream handoff pair for review context.

## Rationale

The command was still advertised as partially supported even though every option currently exposed in `container compose help run` is marked supported and the orchestration path has focused unit coverage. Keeping the help marker partial makes users look for a missing runtime gap that no longer applies to the command itself.

The remaining partially supported commands stay partial. This slice does not claim support for unrelated runtime gaps in `attach`, `build`, `config`, `exec`, or attached foreground `up` log presentation.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'runSupportsOneOffContainersAndOptionFlags|runNoDepsOnlyCreatesSelectedServiceResources|runUseAliasesMapsNetworkAliasesToSingleNetworkAttachment|runCommandAndOptionsAreShownAsSupported'
swift test --disable-automatic-resolution --filter ComposeCLIHelpTests
CONTAINER_BIN=/opt/homebrew/bin/container COMPOSE_TEST_BINARY=/Users/sclarke/github/container-compose/.build/debug/compose CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --skip-build --filter runtimeRunBuildEmitsProgressBeforeBuildOutput
markdownlint STATUS.md docs/upstream/container-compose/ISSUE-compose-run-support-status.md docs/upstream/container-compose/PR-compose-run-support-status.md
git diff --check
```

Before release promotion, run the usual broader local gate:

```sh
make coverage-check
```

## Follow-Ups

- Keep `compose attach` partial until interactive attach and signal proxy behavior is backed by the runtime surface.
- Keep `compose exec` partial until privileged process execution has a supported runtime mapping.
- Attached `compose up` log-presentation flags are covered by later raw-output and timestamp slices; this run slice does not change `up --attach`, `--attach-dependencies`, or exit-control behavior.
