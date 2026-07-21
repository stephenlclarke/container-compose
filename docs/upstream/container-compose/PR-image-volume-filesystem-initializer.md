# Pull Request: add image-volume filesystem initializer

## Summary

- Add a local Compose runtime adapter that seeds an empty ext4 volume from a selected unpacked image subtree.
- Consume the generic Containerization subtree exporter without adding Compose semantics to either Apple fork.
- Preserve populated local volumes and stage every replacement before the atomic target swap.
- Update stack references so CI validates the exact Container and Containerization dependency pair.

## Motivation and context

Docker Compose V2 seeds a fresh volume from image content when Dockerfile `VOLUME` behavior requires it. The current public container-compose lifecycle correctly preflights and rejects that behavior until it can preserve data safely. This pull request adds only the missing macOS-feasible filesystem building block; it does not yet change that public preflight.

## Implementation details

- `Sources/ComposeContainerRuntime/ContainerImageVolumeFilesystemInitializer.swift` defines `ContainerImageVolumeInitializer`, which exports the selected path from an unpacked ext4 image filesystem, creates a same-sized staged ext4 volume, unpacks the archive, and atomically replaces the empty target.
- `ComposeVolumeSummary` now carries local volume options so the replacement retains the runtime's journal configuration.
- `ContainerResourceAPIClient` maps those options from the direct Container API.
- `Tests/ComposeContainerRuntimeTests/ContainerImageVolumeFilesystemInitializerTests.swift` covers first initialization, data reuse, POSIX ownership and modes, a missing image subtree, and an invalid journal setting.
- `Tools/release/stack-refs.json` now matches the exact Container, Containerization, and builder-image metadata that the package consumes.

## Apple-shaped boundary

| Layer | Change |
| --- | --- |
| `apple/containerization` | Existing generic subtree archive export and ext4 primitives only. |
| `apple/container` | Existing image snapshot and volume source APIs only. |
| `container-compose` | The local adapter; no Apple-fork patch and no Docker policy in a fork. |

## Constructible commit map

- Containerization prerequisite: [`b91f20f717439c26d51ae13ad7b172cf86cbabb2`](https://github.com/stephenlclarke/containerization/commit/b91f20f717439c26d51ae13ad7b172cf86cbabb2), `feat(ext4): add subtree archive export`.
- Container prerequisite: [`18b3b9bfc800764bd36698caa46e989a4c46b27c`](https://github.com/stephenlclarke/container/commit/18b3b9bfc800764bd36698caa46e989a4c46b27c), `build(deps): update containerization subtree exporter`.
- Compose implementation: `feat(runtime): add image-volume filesystem initializer`; see the source and test paths above.

## Docker Compose V2 parity

This plumbing slice intentionally does not claim user-visible Docker Compose V2 parity. The existing `Tools/parity/check-compose-image-volumes.sh` continues to document the Docker reference behavior and current Compose preflight. The subsequent Compose-policy slice must add live macOS guest integration coverage for implicit image volumes, named and anonymous volume copy-up, `volume.nocopy`, and populated-volume reuse before the compatibility status can change.

## Validation

```sh
swift test --filter ContainerImageVolumeInitializerTests
swift test --filter ComposeRuntimeSPITests
make stack-consistency
make coverage-check
make check
git diff --check
```

## Compatibility and remaining risks

- Existing CLI behavior does not change: image-declared volume copy-up remains rejected before resource creation.
- The adapter currently treats a volume containing only ext4's `lost+found` directory as empty. The policy layer must call it only for a newly created destination or carry explicit initialization state, so an intentionally empty reused volume is not reseeded.
- The adapter is local-ext4-specific by design; non-local drivers remain unsupported on macOS.
