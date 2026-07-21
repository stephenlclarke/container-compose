# Pull Request: preserve Docker-shaped exec lifecycle events

## Summary

- Pin the generic runtime's Docker-compatible exec event implementation.
- Verify that Compose transparently renders `exec_create`, `exec_start`, and
  `exec_die` with public exec metadata.
- Extend the checked-in Docker Compose V2 event fixture to execute a failing
  command and validate its observed event lifecycle.
- Correct `compose help events` and `STATUS.md`: exec actions are supported,
  and automatic restart is Docker's `die` then `start` sequence.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Compose's event command must expose real runtime behavior without inventing a
Docker API layer. The generic runtime can now emit the exact exec lifecycle
records, so Compose only needs a dependency pin, transparent adapter coverage,
reference-fixture validation, and an accurate user-facing compatibility ledger.

## Apple-shaped boundary

- `apple/containerization`: no change. OCI does not define Docker's event
  stream vocabulary.
- `apple/container`: a generic event projection beside existing process,
  wait, cleanup, and event-broadcaster boundaries.
- `container-compose`: an existing thin adapter forwards the additive generic
  actions. This change deliberately avoids a Compose-specific runtime protocol
  or action translation layer.

## Code map

- `Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json`
  pin the generic runtime source commit.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` proves JSON event
  rendering preserves all exec actions, metadata, and private-label filtering.
- `Tools/parity/check-compose-events.sh` makes Docker Compose V2 execute
  `exit 23`, waits for its exec lifecycle, and checks `execID` and `exitCode`.
- `Sources/ComposePlugin/ComposeCLIHelp.swift`, its test, and `STATUS.md`
  describe the precise remaining action gaps.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Completed locally on macOS:

- `swift test --disable-automatic-resolution --filter
  'eventManagerRelaysDockerExecActions|commandSupportEntriesClassifyKnownGaps'`
  passed both focused tests.
- `bash -n Tools/parity/check-compose-events.sh` and `shellcheck
  Tools/parity/check-compose-events.sh` passed.
- `CONTAINER_COMPOSE_LIVE=0 ./Tools/parity/check-compose-events.sh --strict`
  passed against Docker Compose V2 5.3.1. It observed all three exec actions,
  `execID`, and `exec_die` exit code `23`.
- `.build/debug/compose help events --ansi never` reported the current support
  and limitation text.
- The full coverage measurement for this event slice reported Swift at 91.46%
  and Go at 85.55%. The succeeding remote-resource quality handoff raises Go
  coverage to 90.05% while retaining the higher Swift coverage priority.

## Compatibility and risks

The new event actions are additive. Compose forwards future runtime actions by
default and continues to suppress only generic `delete` because the matching
Docker-shaped `destroy` represents the same removal. Automatic restart remains
accurately visible as `die` then `start`; explicit restart, OOM, rename,
resize, update, attach, and detach actions remain unimplemented.

## container-compose Checks

- [x] I updated `STATUS.md` and `docs/upstream/` for the runtime support
  change.
- [x] This pull request is focused on one coherent event compatibility change.
- [ ] Remote CI is pending the pushed `main` commits; local review notes and
  validation are recorded above.
- [x] I used Conventional Commits in commit messages and the pull request
  title.
- [x] Release-Note: compose events now report Docker-shaped exec lifecycle
  actions when the macOS runtime provides them.
- [x] I included the companion generic-runtime issue and PR handoff below.
- [x] I signed the implementation and documentation commits.
- [x] I removed credentials, tokens, private keys, personal data, and private
  registry details from code, tests, logs, and this handoff.

## Commit tracking

- Generic runtime implementation:
  [`735e8aaec538a1d043d97525074e4175ae1ac10f`](https://github.com/stephenlclarke/container/commit/735e8aaec538a1d043d97525074e4175ae1ac10f),
  `feat(runtime): add exec lifecycle events`.
- Generic runtime handoff:
  [`0ad41c5`](https://github.com/stephenlclarke/container/commit/0ad41c5),
  `docs(handoff): add exec event proposal`.
- Compose implementation:
  [`3c7998e3ea12ecf757b57d0c9b338d18b513725f`](https://github.com/stephenlclarke/container-compose/commit/3c7998e3ea12ecf757b57d0c9b338d18b513725f),
  `feat(events): preserve Docker exec lifecycle actions`.

## Non-goals

- Docker Engine, socket, or API emulation.
- Windows behavior or Linux-only OOM event telemetry.
- Explicit restart, rename, resize, update, attach, detach, and other Docker
  event actions outside the implemented exec lifecycle.
