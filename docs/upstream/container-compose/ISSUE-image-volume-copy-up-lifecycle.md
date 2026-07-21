# Compose volume parity: wire Dockerfile `VOLUME` copy-up into lifecycle commands

## Compose surface

Dockerfile-declared `VOLUME` targets and service volume mounts that cover those targets in `up`, `create`, and one-off `run`.

```dockerfile
VOLUME ["/image-data", "/image-cache"]
```

```yaml
services:
  api:
    image: example/api
    volumes:
      - type: volume
        source: data
        target: /image-data
```

## Problem

The earlier metadata/preflight slice correctly rejected an unmasked declared image volume rather than silently attaching an empty Apple runtime volume. The following filesystem slice supplied a safe local ext4 initializer, but did not choose volumes or invoke it from Compose lifecycle commands. Docker Compose V2 instead creates an implicit volume for every unmasked declared target and copies image data into any empty local volume attached at that target unless `volume.nocopy: true` opts out.

## Implemented behavior

The Compose layer now owns the Docker-specific policy without adding Compose behavior to the Apple forks:

- `up`, `create`, and one-off `run` retain the active pull-policy metadata preparation, then inspect image-declared targets for each concrete container.
- An unmasked declared target receives a deterministic anonymous local volume, scoped to the service replica or one-off container.
- An explicit named or anonymous `type: volume` mount, including a local volume inherited through `volumes_from`, that covers a declared target is initialized from its mount destination; parent mounts correctly seed the parent image subtree.
- `volume.nocopy: true`, an existing `volume.subpath`, bind, tmpfs, and read-only image mounts deliberately skip initialization. Docker requires the subpath before the mount is created, so Compose leaves its parent volume unmodified and delegates secure subpath validation to the generic runtime.
- Generated image volumes carry Compose ownership labels so `down --volumes`, `rm --volumes`, and `--renew-anon-volumes` locate them without rereading an image that may no longer exist.
- A reused volume is passed through the initializer again, which preserves any volume with entries beyond ext4's `lost+found`; `down` followed by `up` therefore retains user data instead of recreating or reseeding it.

## Remaining scope

- Generic local-volume copy-up for an image path not declared with `VOLUME` is implemented separately in [ISSUE-generic-volume-copy-up.md](ISSUE-generic-volume-copy-up.md).
- This implementation intentionally supports only local ext4 volumes. Non-local drivers/plugins, recursive bind semantics, macOS consistency modes, Windows `npipe`, and Swarm cluster/CSI mounts are outside this macOS-feasible slice.

## Apple-shaped boundary

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Generic OCI `Volumes` metadata and selected ext4-subtree archive export. |
| `apple/container` | Generic selected image snapshot and local volume backing-path APIs. |
| `container-compose` | Docker Compose mount selection, `nocopy` policy, lifecycle ownership labels, and parity tests. |

No fork receives Docker Compose types, Compose labels, command handling, or lifecycle policy. This slice consumes the generic prerequisites already carried by the matched stack.

## Required commits and source map

- `stephenlclarke/containerization` [`b91f20f717439c26d51ae13ad7b172cf86cbabb2`](https://github.com/stephenlclarke/containerization/commit/b91f20f717439c26d51ae13ad7b172cf86cbabb2), `feat(ext4): add subtree archive export`.
- `stephenlclarke/container` [`18b3b9bfc800764bd36698caa46e989a4c46b27c`](https://github.com/stephenlclarke/container/commit/18b3b9bfc800764bd36698caa46e989a4c46b27c), `build(deps): update containerization subtree exporter`.
- `container-compose` policy: `Sources/ComposeCore/ComposeOrchestratorImageVolumes.swift`, `Sources/ComposeCore/ComposeOrchestratorMountsContainersVolumes.swift`, `Sources/ComposeCore/ComposeOrchestratorCreateAndLogs.swift`, and `Sources/ComposeCore/ComposeOrchestratorLogsRunDown.swift`.
- `container-compose` runtime boundary: `Sources/ComposeRuntimeSPI/ComposeRuntimeImageVolumes.swift` and `Sources/ComposeContainerRuntime/ContainerClientImageVolumeInitializer.swift`.

## Acceptance criteria

- Implicit, named, and anonymous declared-image volumes are initialized before container creation in `up`, `create`, and `run`.
- `volume.nocopy`, bind, tmpfs, and image masks preserve Docker's no-copy behavior.
- A pre-existing `volume.subpath` on a declared target is mounted without image copy-up and remains unchanged.
- A `down`/`up` cycle preserves a written marker in the retained image volume.
- Lifecycle cleanup finds generated image volumes by labels.
- Unit coverage, Docker Compose V2 reference behavior, normalized model coverage, and live matched-runtime integration coverage are automated.
