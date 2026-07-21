# Project Docker `created` and `exited` service states

## Summary

- Derive Docker `created` from a stopped runtime snapshot that has never
  started, and `exited` from one with a recorded `startedDate`.
- Apply that Compose-owned projection consistently at both the direct API and
  stable CLI JSON discovery boundaries.
- Make `ps --status` and `--filter status=` select `created` and `exited`
  independently; retain Docker Compose V2's nonmatching `stopped` behavior.
- Add a checked-in Docker Compose V2 lifecycle fixture and strict local parity
  target.

## Apple-shaped boundary

No Apple fork changes are required. `apple/container` already persists the
minimal, runtime-native facts: `RuntimeStatus.stopped`, `startedDate`, and exit
metadata. `container-compose` alone translates those facts into Docker's CLI
vocabulary. The change adds no Compose type or Docker state to generic APIs.

## Code map

- `Sources/ComposeContainerRuntime/ContainerDiscoveryAdapter.swift` derives
  `created` and `exited` once for both discovery paths.
- `Sources/ComposeCore/ComposeRenderHelpers.swift` keeps those filters
  independent and keeps legacy `stopped` nonmatching rather than aliasing it.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` covers both
  discovery paths, `ps` filtering, project status summaries, and diagnostics.
- `Tools/parity/fixtures/state-status/compose.yaml` and
  `Tools/parity/check-compose-state-status.sh` confirm the Docker Compose V2
  `create` → `start` → `kill` lifecycle and its exact filtered output.
- `STATUS.md` records `created`/`exited` as implemented and narrows the
  remaining state gap to `dead`, `restarting`, and `removing`.

## Validation

```sh
swift test --disable-automatic-resolution --filter \
  'discoveryManagerMapsContainerSnapshotsToComposeSummaries|cliJSONDiscoveryManagerMapsContainerListOutputToComposeSummaries|psStatusFiltersCreatedContainers|psStatusStoppedDoesNotAliasExited|psFilterStatusSupportsExitedAlias|lsListsComposeProjectsWithGroupedStatus|lsJSONRendersComposeProjects|psRejectsUnsupportedStatusFiltersBeforeRuntimeCommands'
bash -n Tools/parity/check-compose-state-status.sh
shellcheck Tools/parity/check-compose-state-status.sh
make docker-compose-state-status-parity CONTAINER_COMPOSE_LIVE=0
make check
make coverage-check
git diff --check
```

Docker Compose V2 5.3.1 creates both fixture services as `created`, changes
only the killed service to `exited` with exit code 137, and filters `created`,
`exited`, and `stopped` exactly as the Compose adapter presents them.
The full coverage gate passed with 91.45% Swift and 85.55% Go coverage,
exceeding the repository minimums of 90% and 85%.

## Commit tracking

- Compose adapter, tests, fixture, parity target, and status ledger:
  [`e056f2a66d15dd58904e1c6a90245035989be2e2`](https://github.com/stephenlclarke/container-compose/commit/e056f2a66d15dd58904e1c6a90245035989be2e2),
  `feat(state): project created and exited service states`.

## Non-goals

- Docker `dead`, `restarting`, or `removing` state emulation.
- Docker Engine or socket-proxy compatibility.
- Windows-specific or Linux-host-only behavior.
