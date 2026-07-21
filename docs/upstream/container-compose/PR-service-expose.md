# Preserve service exposed ports as generic container metadata

## Summary

- Preserve `services.expose` in the typed create-plan boundary.
- Render each entry as a generic `container --expose` argument.
- Pin the Apple-shaped generic runtime change that persists and validates the
  metadata.
- Add a checked-in Docker Compose V2 fixture and strict parity target for
  configuration plus dry-run argument behavior.
- Update the complete status ledger while retaining the existing Compose CLI
  help surface.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | No change: OCI Runtime Spec has no exposed-port primitive. |
| `apple/container` | Generic `ContainerConfiguration.exposedPorts` and repeatable `create/run --expose` metadata option. |
| `container-compose` | Minimal typed-plan projection from `services.expose`; no Docker Engine emulation or fork-specific protocol. |

The lower-fork capability is independently useful for any macOS client.
Compose remains the adapter and neither fork imports Compose types.

## Code map

- `Sources/ComposeCore/ContainerServiceCreateAdapter.swift` retains exposed
  ports in both the identity and typed create plan.
- `Sources/ComposeCore/ComposeOrchestratorConfigAndLinks.swift` projects
  `service.expose` into that plan.
- `Sources/ComposeCore/ComposeOrchestratorRunCopyStart.swift` emits repeatable
  `--expose` arguments, before the independent `--publish` projection.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` verifies plan
  preservation, all port forms, and the absence of a synthesized `--publish`.
- `Tools/parity/fixtures/exposed-ports/compose.yaml` is the checked-in Docker
  Compose V2 fixture.
- `Tools/parity/check-compose-exposed-ports.sh` compares normalized JSON and
  validates the local dry-run arguments. `Makefile` exposes the strict target.
- `Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json` pin
  the matching generic runtime commit; `STATUS.md` removes the resolved gap.

## Validation

```sh
swift test --disable-automatic-resolution \
  --filter 'ComposeOrchestratorTests.upProjectsServiceExposeThroughTheRuntimeMetadataChannel' \
  --no-parallel
make docker-compose-exposed-ports-parity CONTAINER_COMPOSE_LIVE=0
make check
make coverage-check
.build/debug/compose help
```

Results on macOS:

- The focused service-projection test passed.
- Docker Compose v5.3.1 and `container-compose` both preserve
  `8080`, `8443/udp`, and `9000-9001/tcp`; the Compose dry run emits each
  `--expose` argument and no `--publish` argument.
- The full coverage gate passed with 91.45% Swift coverage and 85.55% Go
  coverage, meeting the repository's 90% and 85% thresholds.
- `make check` passed. `compose help` still accurately presents the existing
  Compose command surface because this YAML attribute adds no user-facing
  Compose CLI switch.

## Compatibility and risks

The adapter is opt-in and leaves existing `ports` behavior untouched. It
requires the pinned `container` fork because stock Apple Container has no
persisted exposed-port field. Exposed ports deliberately do not bind a host
socket, allocate a host port, or alter the macOS host boundary.

## Commit tracking

- Generic `container` primitive, tests, and help text:
  [`2f7b6e4d207027f5b44a27070e0baddbbe42fb76`](https://github.com/stephenlclarke/container/commit/2f7b6e4d207027f5b44a27070e0baddbbe42fb76),
  `feat(runtime): add container exposed-port metadata`.
- `container-compose` adapter, fixture, tests, pins, and status ledger:
  [`c09f5e3e0bbedff40e63a8782847dec625203c40`](https://github.com/stephenlclarke/container-compose/commit/c09f5e3e0bbedff40e63a8782847dec625203c40),
  `feat(metadata): preserve service exposed ports`.
