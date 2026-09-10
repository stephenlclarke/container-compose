# Issue 633: complete stock Engine socket volume initialization

Issue [#633](https://github.com/stephenlclarke/container-compose/issues/633) tracks a stock-profile parity gap discovered by the `devcontainer` real-runtime suite.

## Problem

The stock profile already sends container discovery, lifecycle, network, volume, and image operations to the current user's Container Engine Unix socket. It did not install a `ComposeRuntimeImageVolumeInitializing` provider. A Compose service therefore failed before creation whenever its image declared a volume that Docker Compose would seed from the image filesystem.

The failure was reproduced against unmodified `apple/container` 1.4.1 through the Devcontainer Engine. Docker and Colima were absent from the candidate path.

## Required behavior

- Resolve the named local volume through the current-user Engine socket.
- Preserve a volume that already contains user data.
- Read the requested image subtree through a temporary Engine container and the Engine archive endpoint.
- Seed only the contents of the selected image directory into an empty volume.
- Treat a missing image path as Docker's empty-volume case.
- Remove the temporary container on success, failure, or a concurrent initialization race.
- Keep the implementation independent of Stephen's enhanced Container and Containerization forks.

## Acceptance evidence

- Deterministic Unix-socket component tests cover copy-up, preservation, request routing, and helper cleanup.
- Stock-profile compilation uses exact `apple/container` 1.4.1 and `apple/containerization` 0.45.0 dependencies.
- The downstream `devcontainer` Compose parity fixtures pass against both stock Apple Container and the enhanced Container provider without invoking Docker or Colima.
