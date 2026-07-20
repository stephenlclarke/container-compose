# Pull Request: preflight image-declared volume copy-up

## Summary

- Preserve Docker image `VOLUME` metadata through the matched Containerization and Container forks.
- Preflight image-declared volume targets before `up`, `create`, and one-off `run` allocate Compose resources.
- Permit non-copy-up masks and reject only Docker semantics that require an unavailable image-to-volume initializer.
- Add Docker Compose V2 reference coverage, unit regressions, documentation, and a reproducible handoff.

## Motivation and context

Docker Compose V2 initializes an implicit or regular volume from the image filesystem when the image declares `VOLUME` at that destination. The previous Compose/runtime boundary did not retain the OCI `Volumes` field, so a Compose run could silently create an empty runtime volume rather than preserve Docker's seeded data.

This change makes the available behavior explicit and safe. It does not pretend that a macOS host bind, a helper container, or an empty volume is equivalent to Docker copy-up.

References:

- [Dockerfile `VOLUME` reference](https://docs.docker.com/reference/dockerfile/#volume)
- [Compose service volumes reference](https://docs.docker.com/reference/compose-file/services/#volumes)
- [Compose volume `nocopy` reference](https://docs.docker.com/reference/compose-file/services/#volumes)
- [Image-volume issue handoff](ISSUE-image-declared-volume-copy-up.md)

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | Generic OCI config decoding and encoding for `Volumes`; no Compose types or Docker policy. |
| `apple/container` | Generic image metadata transport; no Compose parsing or lifecycle policy. |
| `container-compose` | Docker-specific preflight, error wording, parity fixture, and user documentation. |

No fork patch attempts to implement Docker copy-up in a platform-specific CLI layer. A future generic runtime initializer can be proposed independently and consumed by the Compose layer when it is accepted.

## Constructible commit map

- Containerization prerequisite: [`20293eeb5aa2dcf992d7adb8d613a4f68b7edd6e`](https://github.com/stephenlclarke/containerization/commit/20293eeb5aa2dcf992d7adb8d613a4f68b7edd6e), `feat(oci): preserve Docker image volume declarations`.
- Container prerequisite: [`169968b42d3376511f492e9e8810896ba02d6231`](https://github.com/stephenlclarke/container/commit/169968b42d3376511f492e9e8810896ba02d6231), `test(images): retain Docker image volume metadata`.
- Compose implementation: this pull request's `feat(runtime): preflight image-declared volume copy-up` commit.

## Implementation details

- `ComposeImageMetadata` now carries `declaredVolumeTargets`.
- The live Container adapter reads the selected image variant's OCI config `Volumes` map and selects platform-specific targets.
- `ComposeOrchestratorImageVolumes` caches this lookup per image/platform during one lifecycle preflight, after honoring the active pull policy and preparing missing default-pull images.
- A target with no Compose mount, or a normal `type: volume` mount, is rejected because Docker would copy image data into it.
- Bind, tmpfs, and image mounts are safe masks. `volume.nocopy: true` is safe because Docker explicitly skips copy-up.
- `Tools/parity/check-compose-image-volumes.sh` builds the Docker Compose V2 fixture, verifies copied seeds and mount identities, then compares the same Compose model through `container-compose`.

## Compatibility

Supported now:

- Reading image-declared `VOLUME` metadata.
- Safe bind, tmpfs, and image masks.
- Explicit `volume.nocopy: true` opt-out.

Deliberately rejected before side effects:

- Unmasked image-declared volumes.
- Named and anonymous volume mounts that would receive Docker copy-up.

Remaining runtime gap:

- Generic image-layer materialization into a fresh managed volume, with OCI filesystem fidelity. This is macOS-feasible inside the Linux guest but cannot be implemented honestly in Compose alone.

## Validation

```sh
swift test --filter 'ComposeCoreTests.ComposeOrchestratorTests/(createRejectsImageVolumesRequiringCopyUpBeforeCreatingResources|upRejectsImageVolumesRequiringCopyUpBeforeCreatingResources|upAcceptsNoCopyVolumesThatMaskImageVolumeTargets|upAcceptsNonCopyUpMasksForImageVolumeTargets|runRejectsImageVolumesRequiringCopyUpBeforeCreatingResources|imageManagerReturnsPlatformImageVolumeTargetsThroughDirectAPI|imageManagerPreparesMissingImageVolumeMetadataThroughDirectAPI)'
bash -n Tools/parity/check-compose-image-volumes.sh
shellcheck Tools/parity/check-compose-image-volumes.sh
Tools/parity/check-compose-image-volumes.sh --help
make docker-compose-image-volumes-parity
make coverage-check
make check
git diff --check
```

## container-compose checks

- [x] `STATUS.md`, `README.md`, and `BUILD.md` describe the same supported and rejected behavior.
- [x] The fork changes are minimal, generic, and independently handoff-ready.
- [x] Unit coverage exercises `up`, `create`, one-off `run`, `nocopy`, and each safe-mask class.
- [x] Docker Compose V2 integration coverage verifies reference copy-up behavior and Compose-model parity.
- [x] This slice has one Conventional Commit and a signed commit before it is pushed to `main`.
