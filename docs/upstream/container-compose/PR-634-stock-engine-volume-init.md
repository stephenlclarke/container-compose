# Pull request 634: complete stock Engine socket volume initialization

Pull request [#634](https://github.com/stephenlclarke/container-compose/pull/634) implements issue [#633](https://github.com/stephenlclarke/container-compose/issues/633).

## Summary

- Wire the stock Engine provider into Compose image-backed volume initialization.
- Resolve the Engine-managed mountpoint and fetch the image subtree through the local Unix socket.
- Preserve populated volumes and remove temporary source containers on every terminal path.

See the companion [issue handoff](ISSUE-633.md).

## Motivation and context

The Docker-free stock profile could already create and manage ordinary Compose resources, but image-declared volumes selected an unconfigured default provider. That made valid Dev Container Compose projects fail before service startup. This change completes the missing provider boundary without importing the enhanced runtime or adding a Docker dependency.

## Implementation

- `Sources/ComposeEngineRuntime/ComposeEngineRuntime.swift`
  - installs `EngineRuntimeProvider` as the image-volume initializer;
  - resolves the authoritative volume over `CONTAINER_COMPOSE_ENGINE_SOCKET`;
  - creates a narrowly labelled temporary source container;
  - downloads the selected image path through the Engine archive endpoint;
  - extracts the selected directory contents only while the volume remains empty; and
  - force-removes the temporary container after success, missing source data, race avoidance, or failure.
- `Tests/ComposeEngineRuntimeTests/ComposeEngineRuntimeTests.swift`
  - proves first-use copy-up, existing-data preservation, platform projection, and helper cleanup over a real local Unix-socket test server.

## Validation

- [x] Focused stock `ComposeEngineRuntimeTests`.
- [x] SwiftFormat and strict SwiftLint for touched Swift sources.
- [ ] Full stock repository test and coverage gates.
- [ ] Downstream real-runtime Dev Container Compose parity on a quiet machine.

## Compatibility and risk

The enhanced Compose profile is unchanged. The stock provider still requires only a local current-user Engine Unix socket and exact tagged Apple packages. Archive payloads remain bounded to 1 GiB, populated volumes are never overwritten, and the temporary container is internal and force-removed. Docker and Colima are reference-oracle software only and are not installed, invoked, or linked by this implementation.

The downstream Devcontainer runtime owns the mountpoint returned by its authenticated current-user socket. A future remote Engine transport would need a server-side volume-copy primitive rather than this local mountpoint contract.

Closes [#633](https://github.com/stephenlclarke/container-compose/issues/633).
