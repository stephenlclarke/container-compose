# Pull Request: wire image-declared volume copy-up into Compose lifecycle commands

## Summary

- Replace the safe preflight rejection with macOS-local Docker Compose V2 behavior for Dockerfile-declared `VOLUME` targets.
- Create and label deterministic implicit image volumes, initialize empty named and anonymous covering volumes, and honor `volume.nocopy: true`.
- Reuse populated volumes through `down`/`up` and include generated volumes in `down --volumes`, `rm --volumes`, and `--renew-anon-volumes` cleanup.
- Add focused unit tests and a Docker Compose V2 fixture whose live macOS leg verifies seed data, `nocopy`, and a retained marker after a second startup.

## Motivation and context

Docker Compose V2 copies image data to a fresh local volume when Dockerfile `VOLUME` metadata identifies the mount destination. The previous Compose preflight made the lack of implementation explicit instead of risking empty-volume data loss. The matched forks now expose only generic image snapshots, volume backing paths, and subtree archive primitives; this pull request composes those primitives at the Compose boundary and keeps Docker policy out of Apple-owned code.

References:

- [Dockerfile `VOLUME` reference](https://docs.docker.com/reference/dockerfile/#volume)
- [Compose service volumes reference](https://docs.docker.com/reference/compose-file/services/#volumes)
- [Compose volume `nocopy` reference](https://docs.docker.com/reference/compose-file/services/#volumes)
- [Issue handoff](ISSUE-image-volume-copy-up-lifecycle.md)

## Implementation details

- `ComposeRuntimeImageVolumeInitializing` is a narrow runtime SPI: Compose provides image, platform, selected image subtree, and runtime volume name; the runtime initializer has no Compose lifecycle knowledge.
- `ContainerClientImageVolumeInitializer` resolves the immutable image snapshot and local volume through direct Container APIs, then delegates empty-volume handling to `ContainerImageVolumeInitializer`.
- `ComposeOrchestratorImageVolumes` chooses implicit or explicit volumes only for Dockerfile-declared targets, skips `nocopy`, existing `volume.subpath`, and non-volume masks, and invokes initialization before the `container run` handoff.
- Implicit and anonymous image volumes get project/container/service ownership labels. Teardown and anonymous-volume renewal query those labels, so cleanup does not depend on an image still being available.
- The normalizer carries `volume.nocopy` as a typed field rather than treating it as an unsupported marker.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | None in this slice; consume the existing generic ext4 subtree archive primitive. |
| `apple/container` | None in this slice; consume the existing generic image snapshot and local volume APIs. |
| `container-compose` | Own all Docker-specific policy, labels, lifecycle behavior, and validation. |

The only fork prerequisites remain independently reviewable generic commits; no Compose-specific behavior is proposed upstream.

## Constructible commit map

- Containerization prerequisite: [`b91f20f717439c26d51ae13ad7b172cf86cbabb2`](https://github.com/stephenlclarke/containerization/commit/b91f20f717439c26d51ae13ad7b172cf86cbabb2), `feat(ext4): add subtree archive export`.
- Container prerequisite: [`18b3b9bfc800764bd36698caa46e989a4c46b27c`](https://github.com/stephenlclarke/container/commit/18b3b9bfc800764bd36698caa46e989a4c46b27c), `build(deps): update containerization subtree exporter`.
- Compose foundation: [`c626b3c54d0022ea30e9b17b3965b782a211bdca`](https://github.com/stephenlclarke/container-compose/commit/c626b3c54d0022ea30e9b17b3965b782a211bdca), `feat(runtime): add image-volume filesystem initializer`.
- Compose lifecycle policy: this pull request's `feat(volumes): wire image-declared volume copy-up` commit; see the source map in the linked issue.

## Docker Compose V2 parity

`Tools/parity/fixtures/image-volumes/compose.yaml` contains an implicit image-volume service, an explicit named override, a `volume.nocopy` service, and a service that mounts a pre-created `volume.subpath`. `Tools/parity/check-compose-image-volumes.sh` asserts Docker Compose V2's seeded content and mount identities, verifies the same Compose-model projection through `container-compose`, and, when `CONTAINER_COMPOSE_LIVE=1`, proves the matched macOS runtime:

1. seeds implicit and explicit image volumes;
2. leaves the `nocopy` and pre-existing `subpath` targets empty while still seeding their other declared target;
3. writes a marker, executes `down`, starts the same project again, and observes that marker unchanged; and
4. removes the project with `down --volumes --remove-orphans`.

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

- This change covers only Dockerfile-declared image volume targets. Docker's generic copy-up for other volume mounts remains intentionally unsupported rather than silently degraded. A `volume.subpath` is already a pre-existing directory by Docker contract, so it is correctly mounted without image copy-up rather than initialized.
- The safe initializer treats only ext4 roots containing `lost+found` as empty. It preserves populated volumes, which is required for Docker-compatible retained-volume reuse.
- The live integration leg runs only against the isolated matched Apple runtime (`CONTAINER_COMPOSE_LIVE=1`); the Docker Compose V2 reference and model checks remain reproducible on a normal local Docker Engine.
