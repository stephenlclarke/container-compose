# Pull Request

## Summary

- Make Compose project named-volume creation idempotent for both current and
  legacy XPC Container error transports.
- Add unit, runtime Compose YAML, and Docker Compose v2 config/dry-run parity
  coverage for named-volume reuse.
- Make the Current-release VHS recording self-contained and fail-closed: it
  starts the exact packaged Container service, removes any old output, renders
  a real monitoring stack, proves `/healthz`, tears down, and confirms the
  project is empty.

## Type of Change

- [x] Docker Compose behavior fix
- [x] Test and parity coverage
- [x] Release workflow and documentation update
- [ ] Apple Container API change
- [ ] Apple Containerization API change

## Apple-Shaped Boundary

The source change is intentionally limited to the Compose resource adapter.
It uses the generic errors already exposed by Container and does not add a
Docker-specific concept to an Apple-facing runtime API. The Docker-shaped
policy—reusing an existing project volume—remains entirely in Compose.

## Commit Tracking

- `bba6f81916a957b02b276a9515f246a032420d53`
  `fix(compose): reuse named volumes in runtime demos`

## Code Map

- `Sources/ComposeContainerRuntime/ContainerResourceAdapter.swift` recognizes
  `ContainerizationError(.exists)` and the narrowly scoped legacy XPC wrapper.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` verifies both
  transports.
- `Tests/ComposeRuntimeTests/Fixtures/volume-reuse/compose.yml` is the real
  named-volume fixture; `ComposeRuntimeSmokeTests.swift` starts it twice and
  verifies the persisted marker.
- `Tools/parity/check-compose-named-volume-reuse.sh` compares Docker Compose
  v2 and container-compose normalized models, then verifies the Compose
  dry-run volume-create and mount plan. `Makefile` includes it in the release
  parity set.
- `.github/workflows/prebuilt-binaries.yml` starts/stops an isolated packaged
  Container service and requires a newly rendered Current demo GIF.
- `docs/container-compose-demo.tape` and `docs/images/container-compose-demo.gif`
  show the slower monitoring-stack start, stats, `ps`, health check, teardown,
  and empty final project.

## Validation

```console
make swift-test
make go-test
make check
DOCKER_COMPOSE=docker-compose \
  CONTAINER_COMPOSE=.build/debug/compose \
  ./Tools/parity/check-compose-named-volume-reuse.sh --strict
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 \
  CONTAINER_BIN=/opt/homebrew/bin/container \
  CONTAINER_COMPOSE_BUILD_INFO=/path/to/matched/build-info.json \
  swift test --filter 'ComposeRuntimeSmokeTests.*runtimeUpReusesExistingNamedVolume'
vhs validate docs/container-compose-demo.tape
vhs docs/container-compose-demo.tape
git diff --check
```

Local results:

- 1,070 coverage-enabled Swift tests passed in 25 suites.
- The focused runtime test passed against the macOS Container service: two
  `up --detach --wait` calls succeeded and the marker remained readable.
- Docker Compose v2 5.3.1 config parity and container-compose dry-run parity
  passed. The local Docker daemon was unavailable; this check intentionally
  does not require it.
- The refreshed 1100×720, 48ms-typing VHS recording completed a full
  monitoring-stack start, stats, `ps`, `/healthz`, `down --volumes`, and an
  empty final `ps --all` table.

## container-compose Checks

- [x] Docker-specific lifecycle policy remains in Compose.
- [x] No Apple runtime fork change is required for this slice.
- [x] Unit, integration, and Docker Compose v2 parity coverage are present.
- [x] The release recording cannot publish a stale local demo asset.
- [x] The implementation commit uses a Conventional Commit subject and a
  verified signature.
