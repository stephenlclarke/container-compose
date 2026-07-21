# Historical Compose runtime foundation: seed an empty local volume from an image subtree

> Historical plumbing handoff. The policy that now consumes this initializer is documented in [ISSUE-image-volume-copy-up-lifecycle.md](ISSUE-image-volume-copy-up-lifecycle.md).

## Compose surface

Dockerfile `VOLUME` declarations need Docker's initial image-to-volume copy-up behavior. The Compose policy work needs one lower-level operation: materialize a selected directory from a resolved image filesystem into a newly empty local volume without starting a helper container.

## Problem

The matched Containerization and Container forks retain OCI image `Volumes` metadata, and Containerization can now export a selected ext4 subtree as an archive. Before this slice, container-compose had no filesystem adapter that could turn that archive into a local Container-managed ext4 volume. The only safe public behavior was therefore to reject requests that required Docker copy-up.

## Scope of this slice

`ContainerImageVolumeInitializer` stages a replacement ext4 volume beside the target, exports the requested image subtree through the generic Containerization API, unpacks that archive with the volume's size and journal settings, and atomically replaces the target only after success. It returns `false` without mutation when the destination already contains data.

This is intentionally not Compose lifecycle policy. It does not create a volume, choose an implicit-image-volume name, decide `nocopy` behavior, or remove the existing `up`, `create`, and `run` preflight. Those Docker-specific decisions remain the next slice.

## Safety and compatibility

- Initialization is restricted to a local ext4 backing file whose root contains only `lost+found`.
- A missing source subtree or invalid journal setting leaves the existing volume unchanged.
- Replacement occurs only after the staged volume is fully formatted and unpacked, so a failure cannot leave a partial target.
- A populated volume is reused unchanged, matching the required repeated `up`/`down` asset-reuse direction.
- The runtime adapter preserves source content, POSIX mode, uid, and gid in the focused regression coverage.

## Apple-shaped boundary

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Generic selected-subtree archive export and ext4 archive unpacking. |
| `apple/container` | Expose unpacked image snapshots and local volume backing paths. |
| `container-compose` | Compose-owned adapter and the later Docker-specific mount and lifecycle policy. |

No fork gains Compose types, Docker flags, or lifecycle behavior.

## Prerequisite commits

- `stephenlclarke/containerization` [`b91f20f717439c26d51ae13ad7b172cf86cbabb2`](https://github.com/stephenlclarke/containerization/commit/b91f20f717439c26d51ae13ad7b172cf86cbabb2), `feat(ext4): add subtree archive export`.
- `stephenlclarke/container` [`18b3b9bfc800764bd36698caa46e989a4c46b27c`](https://github.com/stephenlclarke/container/commit/18b3b9bfc800764bd36698caa46e989a4c46b27c), `build(deps): update containerization subtree exporter`.

## Acceptance criteria

- The adapter seeds an empty local ext4 volume from a selected image subtree.
- A second invocation preserves the populated volume without reinitializing it.
- Source and formatting failures preserve the original empty volume.
- The Compose package and release-stack manifest pin the matching fork commits.
- Docker Compose V2 parity coverage is added only with the following policy slice, when `up`, `create`, and `run` can expose the behavior.
