# Issue 633: complete stock Engine socket volume initialization

Issue [#633](https://github.com/stephenlclarke/container-compose/issues/633) tracks a stock-profile parity gap discovered by the `devcontainer` real-runtime suite.

## Problem

The stock profile already sends container discovery, lifecycle, network, volume, and image operations to the current user's Container Engine Unix socket. It did not install a `ComposeRuntimeImageVolumeInitializing` provider. A Compose service therefore failed before creation whenever its image declared a volume that Docker Compose would seed from the image filesystem.

The failure was reproduced against unmodified `apple/container` 1.4.1 through the Devcontainer Engine. Docker and Colima were absent from the candidate path.

## Required behavior

- Resolve the named local volume through the current-user Engine socket.
- Mount the Engine-owned managed-volume directory into the service rather than creating a disconnected native volume with the same name.
- Execute service commands through Apple Container's native CLI after resolving the Engine identity.
- Preserve a volume that already contains user data.
- Build and cache a project-owned helper layer on the immutable source-image digest through the stock Apple builder, then copy the requested image subtree inside a temporary Engine container so file ownership and modes remain those of the image.
- Seed only the contents of the selected image directory into an empty volume.
- Treat a missing image path as Docker's empty-volume case.
- Remove the temporary container on success, failure, or a concurrent initialization race.
- Serialize initializers for the same volume and helper-image builds across processes so concurrent services preserve first-mount-wins semantics without racing a shared tag.
- Keep the implementation independent of Stephen's enhanced Container and Containerization forks.

## Acceptance evidence

- Deterministic Unix-socket component tests cover the Docker-free build context, digest-and-helper-derived cache identity, copy-up, managed-volume service launch, native exec, ownership-preserving request projection, concurrent serialization, preservation, request routing, and helper cleanup.
- A repeatable real-runtime harness proves the complete path with stock Apple Container, the stock Devcontainer Engine, and stock Compose while no Docker or Colima process participates.
- Stock-profile compilation uses exact `apple/container` 1.4.1 and `apple/containerization` 0.45.0 dependencies.
- The downstream `devcontainer` Compose parity fixtures pass against both stock Apple Container and the enhanced Container provider without invoking Docker or Colima.
