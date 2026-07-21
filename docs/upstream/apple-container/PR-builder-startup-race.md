# Pull Request: serialize startup of a shared BuildKit container

## Summary

- Serialize only the inspect/create/bootstrap critical section for each
  BuildKit container ID across macOS CLI processes.
- Retain concurrent BuildKit build execution after the singleton is ready.
- Make build provenance use the declared Containerization revision, avoiding a
  stale SwiftPM manifest-cache value in packaged output.

## Intended Review Delta

Apply the signed commit
`7be83a26c220722f4186aa9fe7c14ff339141822`
(`fix(build): serialize builder startup`) from `stephenlclarke/container`.

The implementation is restricted to the existing builder lifecycle boundary.
It does not add Compose APIs, modify Linux guest build semantics, or add
Windows behavior. The companion report is
[ISSUE-builder-startup-race.md](ISSUE-builder-startup-race.md).

## Code Map

- `Sources/ContainerCommands/Builder/BuilderStartupLock.swift`: provides a
  scoped macOS advisory lock keyed by app root and builder container ID.
- `Sources/ContainerCommands/Builder/BuilderStart.swift`: holds that lock
  while validating, inspecting, creating, and bootstrapping BuildKit.
- `Package.swift`: shares the declared Containerization revision with build
  provenance so a dependency update cannot report a cached prior revision.
- `Tests/ContainerCommandsTests/BuildCommandTests.swift`: covers lock-file
  lifecycle and nonblocking reuse.

## Validation

```console
swift test --filter ContainerCommandsTests
make coverage
make check
CONTAINER_STACK_REPO=/absolute/path/to/container \
  CONTAINERIZATION_INIT_SOURCE_PATH=/absolute/path/to/containerization \
  make docker-compose-parity
```

The focused command suite passes 176 tests. Complete coverage passes 1,122
unit tests in 128 suites, 237 concurrent integration tests in 26 suites, and
143 serial integration tests in 14 suites. Compose v2 image-volume parity is
the integration proof because it concurrently builds all fixture services from
a cold builder.

## Compatibility and Risks

- A stopped compatible builder is still restarted through the existing path.
- A configuration mismatch remains subject to the existing stop/recreate
  behavior, but cannot race with another client doing the same work.
- The lock uses the Container application root, so independent installations
  retain independent builders.
- The change is macOS host lifecycle behavior only and adds no Windows path.

## Handoff Status

No Apple remote has been pushed. The Compose stack pin must include this
revision for source-matched release and parity validation.
