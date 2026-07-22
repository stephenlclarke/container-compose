# Current release recording must recover only from pre-command VHS transport resets

<!-- markdownlint-disable MD013 -->

## Problem

The Current package workflow for commit
`15098345ec43841a141a54eea5bb0d782c903c57` built the matched macOS runtime and
Compose plugin successfully, but failed before publication when VHS reported:

```text
could not open ttyd: navigation failed: net::ERR_CONNECTION_RESET
```

The failure occurred before VHS reached the tape's first live Container command.
The tape itself remains the required artifact: it must visibly type commands and
show their real output, never replay a transcript or marker sequence.

## Required behavior

- Retry a fresh VHS session only when its log contains the exact pre-command
  `ttyd` connection-reset signature.
- Stop the isolated Container service between transport-only attempts so the
  next recorded terminal starts clean.
- Treat a failed typed command, missing expected output, or a successful
  recorder without a nonempty GIF as an immediate, fail-closed error.
- Bound retries and preserve the direct VHS tape as the sole Current recording
  source.

## Scope and ownership

This is release-runner resilience in the Compose layer. It does not alter the
Container runtime, Containerization, Docker Compose compatibility behavior, or
the terminal demonstration's command/output semantics.

## Commit tracking

- Failing Current package run:
  [29885990747](https://github.com/stephenlclarke/container-compose/actions/runs/29885990747).
- Retry implementation and tests:
  `057fb7a21ee6928553ed5385443308bb695662cc`
  (`fix(release): retry transient vhs terminal resets`).

## Validation

```sh
bash -n Tools/release/record-vhs-live-demo.sh
python3 -m unittest discover Tools/release
vhs validate docs/container-compose-demo.tape
actionlint .github/workflows/prebuilt-binaries.yml
```

The MBP executed the helper with the installed VHS 0.11.0 binary and produced a
1600×720 GIF that types commands and displays their output. Unit tests cover a
recoverable `ttyd` reset, bounded exhaustion, non-retryable live-command
failure, a missing asset, and invalid retry configuration.
