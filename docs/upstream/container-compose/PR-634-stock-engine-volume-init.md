# Pull request 634: complete stock Engine socket volume initialization

Pull request [#634](https://github.com/stephenlclarke/container-compose/pull/634) implements issue [#633](https://github.com/stephenlclarke/container-compose/issues/633).

## Summary

- Wire the stock Engine provider into Compose image-backed volume initialization.
- Add the static initializer as a cached layer on the source image through Apple Container's bundled builder, mount the Engine-managed volume into a temporary derived container, and perform copy-up inside the guest.
- Keep service launches on the Engine-managed volume directory and route `compose exec` to Apple Container's native command rather than a Docker client.
- Preserve populated volumes, recover interrupted publication, and remove temporary source containers on every terminal path.
- Serialize copy-up per volume and restore the selected source directory's numeric owner and mode.

See the companion [issue handoff](ISSUE-633.md).

## Motivation and context

The Docker-free stock profile could already create and manage ordinary Compose resources, but image-declared volumes selected an unconfigured default provider. That made valid Dev Container Compose projects fail before service startup. This change completes the missing provider boundary without importing the enhanced runtime or adding a Docker dependency.

## Implementation

- `Sources/ComposeEngineRuntime/ComposeEngineRuntime.swift`
  - installs `EngineRuntimeProvider` as the image-volume initializer;
  - resolves the authoritative volume over `CONTAINER_COMPOSE_ENGINE_SOCKET`;
  - rewrites stock service launches to bind the Engine-owned managed-volume data directory instead of creating a duplicate Apple ext4 volume with the same name;
  - resolves Engine container identities before using Apple Container's native `container exec`, preserving attached terminal I/O, detached execution, and process status without Docker software;
  - serializes initialization by volume name with a host file lock shared by Compose processes;
  - hashes the source image identity and static initializer to identify a reusable local helper image;
  - uses the immutable repository digest when available and otherwise snapshots a local image behind a unique tag whose image ID is verified before use;
  - serializes cache construction across processes and submits the minimal build context to the local Engine, whose stock Apple provider invokes Apple Container's bundled builder;
  - creates a narrowly labelled temporary derived container with the target volume mounted;
  - selects an internal mount path that cannot obscure the requested image subtree;
  - overrides the source image's user and entrypoint, so scratch and distroless source images need no shell or utilities;
  - copies the selected image directory inside the Linux guest through the project-owned static helper, preserving files, directories, ownership, modes, timestamps, symlinks, hard links, and named pipes;
  - stages the complete tree and writes an fsync-backed guest journal before publishing any entry;
  - records the exact transaction in a private, current-user host sidecar outside the mounted data directory, allowing a later invocation to authenticate and recover only its own interrupted publication;
  - never treats a user-controlled stage-shaped name as internal state without the matching host transaction and validated journal;
  - rolls back every published entry if publication fails in-process;
  - applies the source directory's numeric owner and mode to the volume root;
  - copies only while the mounted volume remains empty; and
  - force-removes the temporary container after success, missing source data, race avoidance, or failure.
- `Tests/ComposeEngineRuntimeTests/ComposeEngineRuntimeTests.swift`
  - proves build-context projection, digest and verified-local-image sources, first-use copy-up, managed-volume launch projection, native exec projection, ownership/mode request projection, cross-provider serialization, existing-data preservation, transaction hardening, platform projection, lock-file hardening, non-overlapping helper mounts, and helper cleanup over a real local Unix-socket test server.
- `Tools/compose-normalizer/cmd/volume-initializer`
  - supplies and tests the Apache-2.0 static Linux arm64 helper without depending on the source image's user, entrypoint, shell, libc, or command-line tools;
  - validates a caller-provided UUID transaction, persists a versioned entry journal before publication, and recovers only that exact transaction after interruption.

## Validation

- [x] Focused stock `ComposeEngineRuntimeTests`.
- [x] SwiftFormat and strict SwiftLint for touched Swift sources.
- [x] `Tools/parity/stock-engine-image-volume-smoke.sh` against stock Apple Container 1.4.1, a stock-profile Devcontainer Engine, and a stock-profile Compose build; no Docker or Colima process is used.
- [ ] Full stock repository test and coverage gates.
- [ ] Downstream real-runtime Dev Container Compose parity on a quiet machine.

## Compatibility and risk

The enhanced Compose profile is unchanged. The stock provider still requires only the Apple `container` executable, a local current-user Engine Unix socket, Apple Container's stock builder, and exact tagged Apple packages. Populated volumes are never overwritten, interrupted copy-up is authenticated and recoverable, concurrent initializers for the same volume are serialized across provider instances and processes, and the temporary container is internal and force-removed. Dockerfile syntax is used only as the stock Apple builder's documented build model; Docker and Colima are reference-oracle software only and are not installed, invoked, linked, or contacted by this implementation.

Stock Apple VirtioFS can reject a timestamp update on the pre-existing mount root with `EPERM`. The helper accepts that transport result only for the mount-root timestamp; child timestamps remain exact, and ownership or mode failures remain fatal unless an immediate guest-side inspection proves the requested value is already effective. This observable mount-root timestamp difference must remain in downstream non-conformance reporting rather than being described as exact metadata parity.

The downstream Devcontainer runtime owns the mountpoint returned by its authenticated current-user socket. A future remote Engine transport would need a server-side volume-copy primitive rather than this local mountpoint contract.

Closes [#633](https://github.com/stephenlclarke/container-compose/issues/633).
