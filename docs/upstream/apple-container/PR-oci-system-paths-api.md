# Handoff: consume and test OCI system-path overrides

<!-- markdownlint-disable MD013 -->

## Summary

- Merge Apple's [#1996](https://github.com/apple/container/pull/1996) with its
  original parentage.
- Preserve the fork's adjacent stop-timeout field during the one-file merge
  overlap.
- Add the focused encoding and runtime-forwarding tests that the upstream pull
  request did not include.
- Keep Compose-specific security-option normalization outside Apple Container.

## Apple-shaped commits

- `f7612ab5a4018086f8daee70d6d11f45cee286ed`
  (`chore(upstream): sync OCI system path API`) adds Apple's optional fields to
  `Sources/ContainerResource/Container/ContainerConfiguration.swift` and
  forwards them in `Sources/Services/RuntimeLinux/Server/RuntimeService.swift`.
- `bfe4d8306b927ae2594704d94701060a39b3dc6d`
  (`test(runtime): cover OCI system path overrides`) adds round-trip/default
  coverage in `Tests/ContainerResourceTests/ContainerConfigurationTests.swift`
  and `Tests/ContainerRuntimeLinuxServerTests/RuntimeServiceHostsTests.swift`.
- `271ba58e88844f3d3708d25eb584e6b4ae441ed5` is the final current fork tip
  after merging Apple's later integration-fixture refactor.

## Compose consumption

Signed Compose commit `d2464978e156d4ab30db104f3e0abf878fb10a0b`
pins `Package.swift`, `Package.resolved`, and release stack provenance to the
same final Container tip. Existing Compose adapters map supported
`security_opt: [systempaths=unconfined]` and `privileged: true` behavior onto
the generic runtime fields.

## Testing

- [x] Four focused configuration round-trip/default tests
- [x] Thirty-four focused runtime-service host/system-path tests
- [x] Full Container unit suite
- [x] Compose unit and live runtime suites
- [x] Strict Docker Compose V2 security and privileged parity contracts
- [x] Signed Conventional Commits

## Upstream disposition

The API itself is already merged by Apple. The two fork commits remain useful
as an exact downstream conflict-resolution and missing-test handoff; only the
test commit is a candidate for a small follow-up if Apple still lacks equivalent
coverage.
