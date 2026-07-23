# Existing fix: expose complete `ContainerTestSupport` dependencies

<!-- markdownlint-disable MD013 -->

Existing upstream pull request: [apple/container#1994](https://github.com/apple/container/pull/1994).

Do not open a duplicate issue. Apple merged the fix as
[`9be73ed6bd12`](https://github.com/apple/container/commit/9be73ed6bd12ce28f6fca499b8da9819df970105)
on 22 July 2026.

## Problem

The new `ContainerTestSupport` library product did not declare every module it
imports. A downstream Swift package could resolve `apple/container` but failed
when it imported `ContainerTestSupport` because the target graph omitted
`Containerization`, `ContainerizationArchive`, `NIOCore`, `NIOHTTP1`,
`NIOPosix`, and `ContainerPlugin`.

This is a package-boundary defect, not Compose behavior. The complete dependency
list belongs in Apple's `Package.swift`; downstream projects should not copy or
redeclare the missing modules.

## Consumed implementation

- Apple merge: `9be73ed6bd12ce28f6fca499b8da9819df970105`.
- Fork merge: `43efb98d07642a619ea2a8b6ef6024cb3dd2c24e`.
- Final refreshed fork tip: `271ba58e88844f3d3708d25eb584e6b4ae441ed5`.
- Compose dependency commit: `d2464978e156d4ab30db104f3e0abf878fb10a0b`.

## Acceptance evidence

- `swift build --target ContainerTestSupport` passes from the fork.
- The complete Container test bundle compiles after the later Apple fixture
  refactor in [apple/container#1993](https://github.com/apple/container/pull/1993).
- `container-compose` resolves the immutable fork revision from both
  `Package.swift` and `Package.resolved`.
- `Tools/release/stack-refs.json` records the same revision for packaged-stack
  provenance.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] This handoff references the merged Apple fix instead of proposing a duplicate.
