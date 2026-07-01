# Mark `compose ps` Supported With Runtime Coverage

## Summary

This change completes the first `ps` support slice:

- Marks `ps` as supported in `container compose help`.
- Adds focused help tests for the supported command/options.
- Adds `ContainerLiveDiscoveryManager` as the default live discovery path:
  project listings use `container list --format json`, while single-container
  detail still uses the direct client.
- Keeps `ContainerClientDiscoveryManager` available and unit-tested for direct
  API mapping.
- Adds a runtime fixture that builds a simple service and verifies
  `ps --format json` plus `ps --services`.

## Rationale

The `ps` projection already depends on the same `ManagedContainer` JSON shape
that the `container` CLI exposes. Using the CLI JSON boundary for list
operations avoids a hard plugin-process crash observed when awaiting direct
`ContainerClient.list` from the Compose binary. Single-container detail stays on
the direct client so existing runtime state such as health remains available to
wait/dependency paths.

## Verification

Local verification for this slice:

```sh
swift test --filter discovery
swift test --filter cliJSON
swift test --filter ComposeCLIHelpTests
make swift-runtime-test
```

Before release promotion, also run:

```sh
make swift-test
make go-test
make coverage-check
markdownlint README.md INSTALL.md BRANCHES.md docs/upstream/container-compose/ISSUE-compose-ps.md docs/upstream/container-compose/PR-compose-ps.md
```

## Follow-Ups

- If the direct `ContainerClient.list(filters:)` crash remains reproducible,
  create a separate Apple-shaped issue/PR with a minimal non-Compose reproducer.
- Health-aware wait behavior still depends on direct single-container detail; do
  not claim health projection from CLI JSON until the container CLI exposes that
  field.
