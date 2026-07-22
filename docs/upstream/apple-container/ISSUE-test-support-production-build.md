# `ContainerTestSupport` must build in production packages

## Context

Apple Container [PR #1887](https://github.com/apple/container/pull/1887)
made `ContainerTestSupport` a public product for downstream test targets. Its
implementation imported Swift Testing unconditionally, which caused the
macOS runtime package to fail when release packaging built every public
library target:

```text
Sources/ContainerTestSupport/BuildFixture.swift:21:8: error: no such module 'Testing'
```

The error was reproduced by the
[Compose prebuilt release job](https://github.com/stephenlclarke/container-compose/actions/runs/29892531597)
for Compose revision `96e33b21`.

## Apple-shaped resolution

`ContainerTestSupport` now conditionally imports Swift Testing, preserves
test metadata when it is available, and uses `CommandError` for assertion
failures when used from a non-test target. A focused support-module test
exercises all success and error paths. The project test gate defaults to
serial execution because concurrent macOS loopback/descriptor tests reliably
abort the shared Swift Testing process.

The correction is generic to the public support product. It contains no
Docker or Compose-specific runtime behavior.

## Validation

On macOS with Swift 6.3.3:

```console
swift test -c debug --filter ContainerTestSupportTests
make BUILD_CONFIGURATION=release build
make test
make check
make coverage-unit
```

The release build passes; the full and coverage gates each pass 1,124 tests
in 130 suites. Unit coverage reports 38.57% lines, 40.31% functions, and
40.38% regions.

## Commit tracking

- Container code: `79415eee4d2f693a2fa90487f2b041ce6ccb3b9e`
  (`fix(tests): build test support without testing`)
- Container main includes the relocated handoff at
  `1c9c8abdf167dd20f5c83c8bb8cff8524cd535ad`.
- Compose pin: `dd1763755e22ec90c84dd25a411d84ee81a177fe`
  (`chore(deps): refresh container test support`).
