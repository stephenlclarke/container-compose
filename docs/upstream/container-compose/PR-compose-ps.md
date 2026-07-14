# Keep `compose ps` on stable JSON discovery

## Summary

This change completes the first `ps` support slice:

- Marks `ps` as supported in `container compose help`.
- Adds focused help tests for the supported command/options.
- Uses `ContainerLiveDiscoveryManager` for both project lists and single-container detail through `container list --format json`.
- Preserves health, exit metadata, mounts, ports, networks, and labels through the CLI JSON projection.
- Keeps `ContainerClientDiscoveryManager` available and unit-tested for direct
  API mapping.
- Adds a runtime fixture that builds a simple service and verifies
  `ps --format json` plus `ps --services`.

## Rationale

The `ps` projection uses the same `ManagedContainer` JSON shape that the `container` CLI exposes. The stable process boundary avoids the Swift task-stack crash tracked by [swiftlang/swift#81771](https://github.com/swiftlang/swift/issues/81771), while the fork-backed `ManagedContainer.health` field now gives detail reads everything required by wait and dependency paths.

## Verification

Local verification for this slice:

```sh
swift test --filter discovery
swift test --filter cliJSON
swift test --filter ComposeCLIHelpTests
make swift-runtime-test
make docker-compose-health-wait-parity
```

Before release promotion, also run:

```sh
make swift-test
make go-test
make coverage-check
markdownlint README.md INSTALL.md BUILD.md docs/upstream/container-compose/ISSUE-compose-ps.md docs/upstream/container-compose/PR-compose-ps.md
```

## Current Boundary

`ContainerClientDiscoveryManager` remains available for focused direct API consumers and unit coverage. Live Compose discovery uses the CLI JSON manager by default until the Swift task-stack issue is fixed in the supported toolchain.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `8b07f6082dd4847efb65ce866cb5881407ca54ae` (`feat(ps): support compose
  ps live discovery`).
