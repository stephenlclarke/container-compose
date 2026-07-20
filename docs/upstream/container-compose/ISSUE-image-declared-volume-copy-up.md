# Compose compatibility gap: image-declared volumes require Docker copy-up

## Compose surface

Dockerfile `VOLUME` declarations and service mounts at the declared destinations.

```dockerfile
VOLUME ["/image-data", "/image-cache"]
```

```yaml
services:
  api:
    image: example/api
    volumes:
      - type: volume
        source: cache
        target: /image-data
```

## Docker Compose V2 behavior

Docker Compose V2 creates a separate anonymous volume for each image-declared destination that is not masked by a service mount. It copies the image's existing destination content into a fresh volume. An explicit named or anonymous volume at the destination also receives that initial copy unless `volume.nocopy: true` is set. Bind, tmpfs, and image mounts mask the image path instead, so they do not require a copy-up.

The checked-in `Tools/parity/fixtures/image-volumes/compose.yaml` is the reproducible Docker Compose V2 fixture. `make docker-compose-image-volumes-parity` confirms the reference engine creates two distinct anonymous volumes, applies the explicit named override, and preserves the image seed files in all volumes that Docker initializes.

## Current container-compose behavior

Earlier builds silently omitted Dockerfile `Volumes` metadata and could create an empty Apple runtime volume where Docker would have copied image data. That is data-loss-prone false parity.

The matched stack now preserves OCI image `Volumes` metadata and `container-compose` preflights `up`, `create`, and one-off `run` after honoring the active pull policy (preparing a missing default-pull image when needed) but before resource creation. It accepts bind, tmpfs, and image mounts that mask the target, and an explicit `volume.nocopy: true` opt-out. It rejects implicit image volumes and regular volume mounts that require copy-up with a precise diagnostic.

## Required runtime primitive

The generic runtime needs an image-to-volume initialization operation that can materialize a selected image variant's filesystem at a fresh volume root while preserving OCI layer semantics, ownership, modes, whiteouts, and hard links. It must not run arbitrary image commands to populate the volume.

Until that primitive exists, Compose must keep the guard rather than emulate copy-up through a macOS host path or an untracked helper container.

## Ownership and Apple-shaped boundary

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Preserve OCI image config `Volumes` metadata; no Docker Compose policy. |
| `apple/container` | Expose the preserved image metadata to consumers; a future generic image-to-volume initializer belongs here or below. |
| `container-compose` | Apply Docker-specific copy-up policy, diagnostics, and configuration parity checks. |

The already-published prerequisite commits are:

- `stephenlclarke/containerization` [`20293eeb5aa2dcf992d7adb8d613a4f68b7edd6e`](https://github.com/stephenlclarke/containerization/commit/20293eeb5aa2dcf992d7adb8d613a4f68b7edd6e), `feat(oci): preserve Docker image volume declarations`.
- `stephenlclarke/container` [`169968b42d3376511f492e9e8810896ba02d6231`](https://github.com/stephenlclarke/container/commit/169968b42d3376511f492e9e8810896ba02d6231), `test(images): retain Docker image volume metadata`.

## Acceptance criteria

- OCI `Volumes` metadata survives the Containerization and Container image APIs.
- Compose rejects every path that needs Docker image-to-volume copy-up before creating networks, volumes, or containers.
- Compose accepts `volume.nocopy: true` and bind, tmpfs, or image masks at declared paths.
- Docker Compose V2 reference behavior, Compose-model projection, and `up`/`create`/`run` unit regressions are automated.
- A future runtime primitive replaces the rejection with a real filesystem materialization operation and adds a live macOS guest integration test.
