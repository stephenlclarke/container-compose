# Pull Request: preserve Docker `volume.subpath` no-copy behavior for image volumes

## Summary

- Remove the false unsupported-feature rejection for a pre-existing `volume.subpath` that covers a Dockerfile-declared `VOLUME`.
- Skip Compose image-volume initialization for that mount, preserving Docker's no-copy behavior and retained volume content.
- Add unit coverage plus Docker Compose V2 model and runtime parity coverage using a one-shot preparer that creates the required subdirectory.
- Update the parity ledger and the related image-volume handoff to record the implemented behavior accurately.

## Motivation and context

Docker requires a volume subdirectory to exist before it can be mounted. As a result, a `volume.subpath` never identifies an empty volume root for Dockerfile image-data copy-up. The previous Compose rejection was safe but unnecessarily prevented a runtime capability that the matched Apple-shaped stack already provides.

References:

- [Docker Compose service volumes reference](https://docs.docker.com/reference/compose-file/services/#volumes)
- [Docker volumes reference](https://docs.docker.com/engine/storage/volumes/)
- [Issue handoff](ISSUE-image-volume-subpath-copy-up.md)
- [Existing runtime subpath handoff](PR-volume-subpath.md)

## Implementation details

- `ComposeOrchestratorImageVolumes` checks `ComposeMount.volumeSubpath` before adding an image-volume initialization request.
- The normal mount rendering path remains unchanged and emits `--mount type=volume,source=…,destination=…,volume-subpath=…`.
- The parity fixture starts a tiny preparer service that creates `nested`, then mounts that existing directory at `/image-data` in an image declaring `/image-data` and `/image-cache` as volumes.
- The checks prove `/image-data/seed.txt` remains absent while `/image-cache/seed.txt` is still copied to its independently created volume.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | None; consume the existing generic secure subpath resolver. |
| `apple/container` | None; consume the existing generic typed mount projection. |
| `container-compose` | Minimal Docker policy correction, tests, fixture, and documentation only. |

This is intentionally a Compose-layer correction. It introduces no Apple-fork dependency, no Docker-specific API, and no new lower-runtime abstraction.

## Constructible commit map

- Runtime prerequisite: `stephenlclarke/containerization` PR #9 and `stephenlclarke/container` PR #21, documented in [PR-volume-subpath.md](PR-volume-subpath.md).
- Image-volume lifecycle foundation: [`0105b5d02d68e18c6f1a7b2584a0820185e929f6`](https://github.com/stephenlclarke/container-compose/commit/0105b5d02d68e18c6f1a7b2584a0820185e929f6), `feat(volumes): wire image-declared volume copy-up`.
- Compose correction: this pull request's `fix(volumes): preserve image volume subpaths` commit.

## Docker Compose V2 parity

`Tools/parity/check-compose-image-volumes.sh --strict` compares both normalizers, starts the Docker Compose V2 reference fixture, and asserts mount identities and contents for implicit, explicit, `nocopy`, and subpath services. With `CONTAINER_COMPOSE_LIVE=1`, it performs the same content assertions against an isolated, matching macOS runtime and verifies retained-volume reuse through `down`/`up`.

The subpath assertion is intentional: a Docker-prepared `nested` directory mounted over `/image-data` contains no copied `seed.txt`; the image's independent `/image-cache` volume still contains its seed.

## Validation

```sh
swift test --filter 'ComposeOrchestratorTests'
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

- Compose retains Docker's requirement that the subpath already exists. It does not create it, export image data into it, or relax secure runtime validation.
- Docker's generic copy-up for volume mounts outside Dockerfile-declared image targets remains unsupported and is still listed in `STATUS.md`.
- The live integration leg is deliberately restricted to an isolated runtime matching the checked-in stack refs; Docker Compose V2 reference and normalized-model checks remain reproducible on a standard local Docker Engine.
