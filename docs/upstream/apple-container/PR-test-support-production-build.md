# PR handoff: build public ContainerTestSupport without Swift Testing

## Summary

Make Apple Container's public `ContainerTestSupport` product buildable in a
production package where Swift Testing is unavailable. This restores Compose
prebuilt runtime packaging after the fixture extraction in
[Apple Container PR #1887](https://github.com/apple/container/pull/1887).

## Apple-shaped boundary

- Keep the public support product and its downstream import path unchanged.
- Guard optional test metadata with `canImport(Testing)`.
- Report assertion failure through the existing `CommandError` channel.
- Cover file and image helper success plus every assertion error with a fake
  `container` CLI.
- Stabilize the macOS project test gate without changing Container runtime,
  service, API, or Compose behavior.

## Code map

| Path | Change |
| --- | --- |
| `Sources/ContainerTestSupport/ContainerFixture.swift` | Optional Swift Testing import and production-safe fixture identity. |
| `Sources/ContainerTestSupport/BuildFixture.swift` | Error-based file assertions. |
| `Sources/ContainerTestSupport/ContainerFixture+ImageHelpers.swift` | Error-based image assertion. |
| `Sources/ContainerTestSupport/ContainerFixture+MachineHelpers.swift` | Removes unused test-only import. |
| `Package.swift` and `Tests/ContainerTestSupportTests/` | Focused support-product test target. |
| `Makefile` | Deterministic macOS test/coverage invocation. |

## Validation

```console
swift test -c debug --filter ContainerTestSupportTests
make BUILD_CONFIGURATION=release build
make test
make check
make coverage-unit
```

All commands pass on macOS. The full and coverage gates execute 1,124 tests
in 130 suites. Docker Compose V2 parity is not applicable to the
source-only Apple change; it is required for the dependent Compose pin.

The dependent Compose stack's clean `make release-gate` also passed on
2026-07-22. It exercised 25 live Compose runtime tests and the strict Docker
Compose V2 interface-parity matrix against `docker compose` 5.3.1. The only
explicit exception was the separately tracked Phase 5 Apple Builder gap; it
does not cover this public-support-product build path.

## PR template

### Type of change

- [x] Bug fix
- [x] Buildability and test coverage
- [x] Documentation
- [ ] Breaking change

### Motivation and context

Public products are built during release packaging. A test support library
must not require a test-only module simply to compile, while downstream test
callers retain their current API and failure semantics.

### Testing

- [x] Reproduced on the macOS release packaging path
- [x] Focused support-product test added
- [x] Full unit and coverage gates passed
- [x] Formatting and license checks passed
- [ ] Docker Compose V2 parity (not applicable to Apple source-only change)

## Commit tracking

- `79415eee4d2f693a2fa90487f2b041ce6ccb3b9e`
  (`fix(tests): build test support without testing`)
- Dependent Compose pin: `dd1763755e22ec90c84dd25a411d84ee81a177fe`
  (`chore(deps): refresh container test support`).
