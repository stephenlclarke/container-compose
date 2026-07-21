# Preserve Docker-shaped terminal lifecycle events

## Summary

- Pin the generic runtime's `kill`, `die`, and `destroy` event implementation.
- Render the three Docker-shaped actions through the Compose event adapter.
- Filter the retained generic `delete` event at the Compose boundary to prevent
  duplicate removal output.
- Add a checked-in Docker Compose V2 fixture that proves `create`, `start`,
  `kill`, `die`, and `destroy` for a selected service.
- Make `compose help events` state the exact terminal action gaps that remain.

## Apple-shaped boundary

- `apple/containerization`: no change. OCI has no Docker event-stream model.
- `apple/container`: generic event projection, using existing signal, exit,
  and cleanup boundaries. It retains generic `delete` for its clients.
- `container-compose`: one renderer filter plus dependency pin, parity fixture,
  tests, status documentation, and accurate command help.

Compose owns the Docker presentation rule. The generic runtime does not learn
about Compose projects, labels, or Docker's CLI surface.

## Code map

- `Sources/ComposeContainerRuntime/ContainerEventsAdapter.swift` filters the
  generic `delete` action before project and service rendering.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` proves that `kill`,
  `die`, and `destroy` are relayed with public attributes and `delete` is not.
- `Sources/ComposePlugin/ComposeCLIHelp.swift` and its test explain the
  remaining vocabulary accurately.
- `Tools/parity/fixtures/events/compose.yaml` is the checked-in reference
  project. `Tools/parity/check-compose-events.sh` observes Docker Compose V2
  actions and validates the selected-service event stream.
- `Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json` pin
  the matching generic runtime commit.

## Validation

Completed locally on macOS:

```sh
swift test --disable-automatic-resolution \
  --filter 'ComposeOrchestratorTests.eventManagerRelaysDockerTerminalActionsAndHidesGenericDelete' \
  --no-parallel
swift test --disable-automatic-resolution \
  --filter 'ComposeCLIHelpTests.commandSupportEntriesClassifyKnownGaps' \
  --no-parallel
make docker-compose-events-parity CONTAINER_COMPOSE_LIVE=0
make check
make coverage-check
bash -n Tools/parity/check-compose-events.sh
shellcheck Tools/parity/check-compose-events.sh
.build/debug/compose help
git diff --check
```

Both focused Swift tests passed. Docker Compose V2 5.3.1 produced the required
terminal action set using the checked-in fixture. The strict parity target
passed with the local Compose runtime disabled, so the Docker reference is an
independent V2 comparison. `make check` passed. The full coverage gate passed
with 91.46% Swift coverage and 85.55% Go coverage, exceeding the repository
minimums of 90% and 85%.

## Compatibility and risks

The runtime still publishes generic `delete` for existing clients. Only Compose
suppresses it, because the following Docker-shaped `destroy` event represents
the same removal. The adapter forwards unknown future actions unchanged. OOM,
automatic restart, rename, resize, update, attach/detach, and exec event
semantics remain unimplemented and are explicitly retained in the status
ledger and command help.

## Commit tracking

- Generic event primitive:
  [`7ed57b18a7dbadddea21007d0a2c17d0ae399fa0`](https://github.com/stephenlclarke/container/commit/7ed57b18a7dbadddea21007d0a2c17d0ae399fa0),
  `feat(runtime): add Docker terminal lifecycle events`.
- Compose adapter, fixture, package pin, status ledger, and help:
  [`4a4396544200419011b5afc5eb896821a0a059bc`](https://github.com/stephenlclarke/container-compose/commit/4a4396544200419011b5afc5eb896821a0a059bc),
  `feat(events): preserve Docker terminal lifecycle actions`.

## Non-goals

- Docker Engine or API socket emulation.
- Windows event behavior or Linux-only OOM telemetry.
- Automatic restart, rename, resize, update, attach/detach, or exec action
  implementation.
