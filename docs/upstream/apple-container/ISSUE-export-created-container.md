# Export a never-started container

## Summary

`container export` should export a container immediately after `container create`, without requiring the container to be started first.

## Current Behavior

Container creation records the selected image snapshot in `runtime-configuration.json`, while the writable bundle disk `rootfs.ext4` is materialized when the runtime first starts the container. `ContainersService.exportRootfs` reads only the bundle disk, so exporting a never-started container fails with a missing-file error.

## Expected Behavior

- A stopped container with a materialized bundle exports its writable `rootfs.ext4` as it does today.
- A never-started container exports the immutable image snapshot recorded in its runtime configuration.
- Both ordinary image snapshots and ext4 block rootfs overrides are accepted.
- Unsupported filesystem formats return an explicit unsupported error.
- Export does not boot a VM or mutate the container lifecycle state.

## Motivation

Export is a filesystem operation and should not require executing untrusted image content merely to make the root filesystem readable. Compose Bridge uses this behavior to recover transformer templates from a created image container, but the capability is generic and also benefits inspection, backup, migration, and image tooling.

## Ownership

- `apple/container` owns container lifecycle metadata and rootfs export.
- `containerization` owns secure archive extraction.
- `container-compose` owns transformer selection and template policy.

## Upstream Context

- Export semantics issue: <https://github.com/apple/container/issues/1265>
- Tar archive export implementation: <https://github.com/apple/container/pull/1303>
- Docker Compose transformer creation: <https://github.com/docker/compose/blob/main/pkg/bridge/transformers.go>

## Acceptance Criteria

- Create an Alpine container without starting it.
- Export it to a tar archive.
- Read `/etc/alpine-release` from the archive.
- Confirm existing stopped-after-run export coverage still passes.
- Confirm malformed materialized bundle metadata is reported instead of falling back to the image snapshot.
- Confirm unit, formatting, and license gates pass.
