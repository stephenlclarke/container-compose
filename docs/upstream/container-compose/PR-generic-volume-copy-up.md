# Pull Request: seed generic local volume mounts from image paths

## Summary

- Implement Docker Compose V2 copy-up for empty local volume mounts at existing image paths, including paths not declared with Dockerfile `VOLUME`.
- Preserve Docker no-copy behavior for `volume.nocopy`, `volume.subpath`, and missing image paths.
- Create ordinary anonymous volumes before initialization, while retaining the existing labels and lifecycle behavior for Dockerfile-declared implicit volumes.
- Extend unit and Docker Compose V2 integration coverage to prove named, anonymous, no-copy, missing-path, and retained-volume behavior.

## Motivation and context

Docker's volume engine copies an image directory into a newly empty local volume based on the mount destination; Dockerfile `VOLUME` metadata additionally creates an implicit mount when no service mount masks it. The completed declared-volume lifecycle slice implemented the second behavior, but intentionally did not seed an explicit volume at an ordinary image directory. This change closes that macOS-feasible Compose policy gap without changing Apple runtime APIs.

References:

- [Docker volumes: populate a volume using a container](https://docs.docker.com/engine/storage/volumes/#mounting-a-volume-over-existing-data)
- [Compose service volumes reference](https://docs.docker.com/reference/compose-file/services/#volumes)
- [Issue handoff](ISSUE-generic-volume-copy-up.md)

## Implementation details

- Keep Dockerfile-declared-target handling in its existing pass so generated implicit volumes retain Compose ownership labels.
- Add a generic local-volume pass for explicit `volume` and `external-volume` mounts that do not already cover a declared target.
- Pre-create ordinary anonymous volumes before initialization, allowing the local ext4 initializer to seed them deterministically rather than relying on runtime auto-creation during `run`.
- Convert only `EXT4.PathIOError.notFound` into a no-op. This directly models Docker's empty volume at a missing image path, while preserving errors and the existing staged atomic replacement for every other failure.
- Restore the selected image directory's mode and full UID/GID on the initialized volume root. Subtree export correctly places the directory's children at the target root, but does not archive the selected directory itself; without this narrow metadata restore, a non-root image process can lose write access to its own data directory.
- Do not change forked code. The existing generic image snapshot, local volume, subtree export, and idempotent volume-create primitives are sufficient.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | None. Consume existing typed ext4 missing-path errors and subtree export. |
| `apple/container` | None. Consume existing local-volume and image filesystem primitives. |
| `container-compose` | Own Docker-specific mount selection, copy-up exclusions, anonymous-volume timing, documentation, and validation. |

This is intentionally a Compose-layer policy change. It is not a request for Apple to carry Docker Compose terminology, labels, or command behavior in either fork.

## Constructible commit map

- Compose implementation: this pull request's signed `feat(volumes): seed generic local volume mounts` commit. Replace this line with the resulting commit permalink before submitting a handoff.
- Root-metadata correction: this slice's signed `fix(volumes): preserve image volume root metadata` commit. Replace this line with the resulting commit permalink before submitting a handoff.
- Generic ext4 prerequisite: [`b91f20f717439c26d51ae13ad7b172cf86cbabb2`](https://github.com/stephenlclarke/containerization/commit/b91f20f717439c26d51ae13ad7b172cf86cbabb2), `feat(ext4): add subtree archive export`.
- Container prerequisite: [`18b3b9bfc800764bd36698caa46e989a4c46b27c`](https://github.com/stephenlclarke/container/commit/18b3b9bfc800764bd36698caa46e989a4c46b27c), `build(deps): update containerization subtree exporter`.
- Earlier Compose lifecycle policy: [`0105b5d02d68e18c6f1a7b2584a0820185e929f6`](https://github.com/stephenlclarke/container-compose/commit/0105b5d02d68e18c6f1a7b2584a0820185e929f6), `feat(volumes): wire image-declared volume copy-up`.

## Docker Compose V2 parity

`Tools/parity/fixtures/image-volumes/compose.yaml` pairs an image with Dockerfile `VOLUME` targets and a second image that contains `/generic-data` but declares no volumes. The parity script verifies Docker Compose V2 and `container-compose` normalized models, then runs Docker Compose V2 to confirm:

1. named and anonymous generic local mounts receive `/generic-data/seed.txt`;
2. `volume.nocopy` and a mount at `/not-in-image` remain empty;
3. named, anonymous, no-copy, and missing-path mounts have the expected runtime identities; and
4. when the matched macOS runtime is requested, a generic named-volume marker survives `down` then `up` alongside the declared-volume retained marker.

The focused filesystem regression also verifies that a `nobody`-owned `0755` selected image directory becomes a `nobody`-owned `0755` volume root. `Tools/parity/fixtures/image-volumes/Dockerfile.nonroot` and its Compose service provide the corresponding Docker Compose V2 integration reference: the image starts as UID/GID `65534` and writes to its copied-up named volume. The matched macOS runtime check asserts the same write succeeds. This mirrors the Prometheus image's `/prometheus` volume path and prevents a failed startup caused by a root-owned initialized volume.

## Validation

```sh
swift test --filter 'ComposeOrchestratorTests|ContainerImageVolumeInitializerTests'
go test ./...
bash -n Tools/parity/check-compose-image-volumes.sh
shellcheck Tools/parity/check-compose-image-volumes.sh
Tools/parity/check-compose-image-volumes.sh --help
make docker-compose-image-volumes-parity
make stack-consistency
make coverage-check
make check
git diff --check
```

## Compatibility and remaining risks

- This closes generic copy-up for the macOS-supported local ext4 volume path only. Non-local drivers/plugins, recursive bind semantics, consistency/cache modes, Windows `npipe`, and Swarm cluster/CSI mounts remain outside the supported surface.
- A populated volume is retained, based on the local ext4 root containing entries beyond `lost+found`. The change never clears or recreates an existing volume.
- The optional live test requires an isolated, source-matched Apple runtime; Docker Compose V2 reference and normalized-model checks run locally with Docker Engine.
