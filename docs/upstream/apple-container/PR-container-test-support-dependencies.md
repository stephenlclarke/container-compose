# Handoff: consume complete `ContainerTestSupport` dependencies

<!-- markdownlint-disable MD013 -->

## Summary

- Merge Apple's [#1994](https://github.com/apple/container/pull/1994) without
  rewriting its history.
- Preserve the six target dependencies exactly as Apple shipped them.
- Pin Compose and release provenance to the resulting signed fork tip.

## Change map

| Repository | Commit | Purpose |
| --- | --- | --- |
| `apple/container` | `9be73ed6bd12ce28f6fca499b8da9819df970105` | Declares the six missing `ContainerTestSupport` dependencies. |
| `stephenlclarke/container` | `43efb98d07642a619ea2a8b6ef6024cb3dd2c24e` | Signed merge retaining Apple parentage. |
| `stephenlclarke/container` | `271ba58e88844f3d3708d25eb584e6b4ae441ed5` | Final current tip after the subsequent Apple fixture sync. |
| `stephenlclarke/container-compose` | `d2464978e156d4ab30db104f3e0abf878fb10a0b` | Updates SwiftPM, release provenance, and README stack metadata together. |

The Apple code change is confined to the `ContainerTestSupport` target entry in
`Package.swift`. No runtime or Docker-specific policy is added to the fork.

## Validation

- [x] `swift build --target ContainerTestSupport`
- [x] `make check`
- [x] Container unit tests
- [x] Container integration-test bundle compilation after `apple/container#1993`
- [x] Compose stack-consistency and package-resolution checks
- [x] Signed Conventional Commits

## Upstream disposition

Apple has already merged the source fix. This document is a downstream
consumption and release-provenance handoff; it should not be submitted as a new
Apple pull request.
