# Compose parity: seed local volumes at ordinary image paths

## Compose surface

An explicit local volume mount is seeded from the image directory at its target even when the image does not declare that target with Dockerfile `VOLUME`.

```yaml
services:
  api:
    image: example/api
    volumes:
      - type: volume
        source: data
        target: /var/lib/api
```

Docker Compose V2 copies the existing `/var/lib/api` image contents into a fresh `data` volume. It leaves a fresh volume empty for a missing image path, `volume.nocopy: true`, or a pre-existing `volume.subpath`; it does not reseed a populated volume after `down` then `up`.

## Problem

The completed image-declared-volume lifecycle policy initialized local volumes only when OCI image metadata contained a matching Dockerfile `VOLUME` target. That restriction avoided accidental initialization before the generic runtime boundary could distinguish an absent source path from a failed archive export, but it left ordinary local mounts observably different from Docker Compose V2.

## Implemented behavior

- `ComposeOrchestratorImageVolumes` retains the existing Dockerfile-declared target path and adds a second policy pass over eligible explicit `volume` and `external-volume` mounts that are not already covered by one of those targets.
- An anonymous ordinary mount is created before initialization, so the runtime never sees a late auto-created empty volume. It carries no image-declared-volume ownership label because normal anonymous-volume lifecycle discovery already owns it.
- A named or external local volume is initialized through the same narrow `ComposeRuntimeImageVolumeInitializing` SPI.
- `volume.nocopy`, `volume.subpath`, bind, tmpfs, and image mounts are deliberately excluded. Declared targets retain their existing labels and implicit mount creation path.
- `ContainerImageVolumeInitializer` translates only the generic ext4 `PathIOError.notFound` source condition into a no-op result. Other archive and filesystem errors still fail atomically, leaving the target unchanged.
- The selected image directory becomes the volume root after subtree export, so its mode and UID/GID are restored on the new ext4 root. This preserves write access for an image process that does not run as root, including Prometheus's `nobody`-owned `/prometheus` directory.

## Apple-shaped boundary

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | No change. It already exposes generic ext4 subtree export and typed missing-path errors. |
| `apple/container` | No change. It already exposes resolved image filesystems and local-volume backing paths, and idempotent volume creation. |
| `container-compose` | Docker Compose copy-up selection, anonymous-volume timing, `nocopy`/subpath policy, and parity coverage. |

No Docker or Compose concept is added to an Apple-owned fork. The only lower-layer semantic used here is the existing generic `PathIOError.notFound` result for an ext4 source path.

## Required source and commit map

- `Sources/ComposeCore/ComposeOrchestratorImageVolumes.swift`: generic local-mount selection, separate image-declared versus ordinary anonymous-volume creation, and image-path initialization requests.
- `Sources/ComposeContainerRuntime/ContainerImageVolumeFilesystemInitializer.swift`: absent image path leaves an empty volume unchanged and the selected image directory's root ownership/mode survives copy-up.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift`: named, anonymous, and `nocopy` generic policy coverage.
- `Tests/ComposeContainerRuntimeTests/ContainerImageVolumeFilesystemInitializerTests.swift`: typed missing-path no-op and non-root selected-directory metadata coverage.
- `Tools/parity/fixtures/image-volumes/Dockerfile.generic`, `Dockerfile.nonroot`, `compose.yaml`, and `Tools/parity/check-compose-image-volumes.sh`: Docker Compose V2 reference, normalized-model, and optional matched-runtime integration coverage, including retained generic volume reuse and a non-root image process writing to its copied-up volume root.
- This slice's signed `container-compose` commit: `feat(volumes): seed generic local volume mounts` (replace this line with the final commit permalink when proposing the change upstream).
- Existing generic prerequisites, unchanged: `stephenlclarke/containerization` [`b91f20f717439c26d51ae13ad7b172cf86cbabb2`](https://github.com/stephenlclarke/containerization/commit/b91f20f717439c26d51ae13ad7b172cf86cbabb2), `feat(ext4): add subtree archive export`; `stephenlclarke/container` [`18b3b9bfc800764bd36698caa46e989a4c46b27c`](https://github.com/stephenlclarke/container/commit/18b3b9bfc800764bd36698caa46e989a4c46b27c), `build(deps): update containerization subtree exporter`.
- This slice's signed `container-compose` commit: `fix(volumes): preserve image volume root metadata` (replace this line with the final commit permalink when proposing the change upstream).

## Acceptance criteria

- Empty named, anonymous, and inherited local volume mounts at an existing ordinary image directory receive that directory's image contents before container creation.
- The target volume root has the selected image directory's mode and full UID/GID, so a non-root image user can write to it after copy-up.
- A missing image directory, `volume.nocopy`, and a pre-existing `volume.subpath` leave the target volume unchanged.
- Existing content survives `down` then `up` without reseeding.
- Dockerfile-declared target behavior and its cleanup labels remain unchanged.
- The Docker Compose V2 reference, Compose model, focused unit tests, and optional matched macOS runtime coverage are automated.
