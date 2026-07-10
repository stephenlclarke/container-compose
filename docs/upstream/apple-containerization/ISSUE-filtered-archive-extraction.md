# Extract selected archive members securely

## Summary

`ContainerizationArchive.ArchiveReader` should support extracting only members selected by a caller-provided path predicate. Consumers that need one subtree from a large archive should not have to materialize the complete archive or reimplement secure extraction.

## Expected Behavior

- The existing `extractContents(to:)` behavior remains unchanged.
- A new overload accepts a member-path predicate and extracts only matching entries.
- Excluded entry payloads are skipped through libarchive.
- Selected entries retain descriptor-relative traversal protection, symlink handling, permissions, and last-entry-wins behavior.
- Rejected-path results contain only selected entries.
- An archive with no selected entries reports the same empty-archive error contract.

## Motivation

`apple/container` already exports a stopped container root filesystem as a tar archive through the work merged in `apple/container#1303` from `apple/container#1265`. A generic selection API lets clients recover a single directory from that export without adding stopped-container copy semantics or application-specific behavior to Apple-backed layers.

Compose Bridge uses this primitive to recover `/templates` from a stopped transformer container. The API itself is not Compose-specific and is also useful for image, backup, inspection, and migration tooling.

## Ownership

- `containerization` owns archive iteration and secure extraction.
- `apple/container` owns stopped-container rootfs export.
- `container-compose` owns Bridge template selection and transformer lifecycle behavior.

## Upstream Context

- Rootfs export request: <https://github.com/apple/container/issues/1265>
- Rootfs export implementation: <https://github.com/apple/container/pull/1303>
- Docker Compose transformer creation: <https://github.com/docker/compose/blob/main/pkg/bridge/transformers.go>

No matching `apple/containerization` issue or pull request was found when this change was prepared.

## Validation Expectations

- Selected regular files, directories, and symbolic links are extracted.
- Unselected members are absent from the destination.
- A predicate with no matches throws.
- Existing archive security and extraction tests remain green.
