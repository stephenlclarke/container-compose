# Issue 633: complete stock Engine socket volume initialization

Issue [#633](https://github.com/stephenlclarke/container-compose/issues/633) tracks a stock-profile parity gap discovered by the `devcontainer` real-runtime suite.

## Problem

The stock profile already sends container discovery, lifecycle, network, volume, and image operations to the current user's Container Engine Unix socket. It did not install a `ComposeRuntimeImageVolumeInitializing` provider. A Compose service therefore failed before creation whenever its image declared a volume that Docker Compose would seed from the image filesystem.

The failure was reproduced against unmodified `apple/container` 1.4.1 through the Devcontainer Engine. Docker and Colima were absent from the candidate path.

## Required behavior

- Resolve the named local volume through the current-user Engine socket.
- Mount the Engine-owned managed-volume directory into the service rather than creating a disconnected native volume with the same name.
- Preserve a requested `volume.subpath` by binding the resolved descendant and removing volume-only options from the rewritten bind mount.
- Execute service commands through Apple Container's native CLI after resolving the Engine identity.
- Preserve a volume that already contains user data.
- Build and cache a project-owned helper layer through the stock Apple builder. Use an immutable repository digest when one exists; otherwise snapshot the local image behind a unique tag and verify its image identity before building.
- Copy the requested image subtree inside a temporary Engine container so file ownership and modes remain those of the image.
- Install and select native static helpers for both `linux/arm64` and `linux/amd64`, including when Homebrew exposes `compose` through a symlinked prefix.
- Preserve extended attributes, including Linux file-capability metadata, together with ownership, modes, timestamps, links, and named pipes.
- Synchronize copied file data, directories, the destination root, and journal removal in publication order before reporting success.
- Seed only the contents of the selected image directory into an empty volume.
- Treat a missing image path as Docker's empty-volume case.
- Remove the temporary container on success, failure, or a concurrent initialization race.
- Serialize initializers for the same volume and helper-image builds across processes so concurrent services preserve first-mount-wins semantics without racing a shared tag.
- Recover an interrupted multi-entry publication only when a private host transaction identifies the exact guest journal; never infer internal state from user-controlled filename prefixes.
- Recover that authenticated transaction before inspecting the current image path, so a changed or missing source cannot turn partial publication into accepted user data.
- Restore the original mount-root owner, group, and mode during authenticated recovery, then synchronize rollback deletions before accepting the volume as empty.
- Choose an exact helper executable path and target-volume mount path outside the image subtree being copied, so an existing image directory cannot collide with the helper installation.
- Keep the implementation independent of Stephen's enhanced Container and Containerization forks.

## Acceptance evidence

- Deterministic Unix-socket component tests cover the Docker-free build context, platform/name/bytes-derived helper identity, Homebrew symlink resolution, verified local-image snapshots, copy-up, extended attributes, crash recovery including mount-root metadata restoration, durable rollback publication, transaction hardening, user-data preservation, managed-volume service launch, native exec, ownership-preserving request projection, concurrent serialization, request routing, collision-resistant helper placement, and helper cleanup.
- A repeatable real-runtime harness proves the complete path with stock Apple Container, the stock Devcontainer Engine, and stock Compose while no Docker or Colima process participates.
- Stock-profile compilation uses exact `apple/container` 1.4.1 and `apple/containerization` 0.45.0 dependencies.
- The downstream `devcontainer` Compose parity fixtures pass against both stock Apple Container and the enhanced Container provider without invoking Docker or Colima.
