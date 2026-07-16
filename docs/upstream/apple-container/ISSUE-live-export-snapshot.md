# Export a filesystem-consistent snapshot of a running container

## Summary

`container export --live` should create an archive from a running container by
briefly freezing its root filesystem, copying the ext4 disk to a private
temporary location, thawing the filesystem, and exporting the copy. The
primitive is generic: backup, inspection, migration, and higher-level clients
can use it without adding Docker or Compose policy to `apple/container`.

## Current Context

- [apple/container#1400](https://github.com/apple/container/issues/1400) tracks
  live filesystem export/commit consistency.
- [apple/container#1630](https://github.com/apple/container/pull/1630) provides
  the direct live-export direction and is the base for this fork slice.
- [apple/containerization#685](https://github.com/apple/containerization/pull/685)
  provides the lower-runtime freeze/thaw operations.
- [apple/container#1762](https://github.com/apple/container/pull/1762) is a
  Docker-shaped `container commit` draft. It is intentionally out of scope:
  image metadata and Compose service policy belong above the runtime.

## Acceptance Criteria

- `container export --live --output snapshot.tar ID` succeeds for a running
  container and leaves it running.
- The runtime serializes lifecycle and snapshot work while it freezes, copies,
  and thaws the root filesystem.
- Each request uses a unique temporary snapshot and removes it after export.
- A copy failure still attempts to thaw the filesystem before returning the
  original error.
- Stopped and never-started export behavior is unchanged.
- Focused guest integration, full unit tests, formatting, and license checks
  pass.

## Non-Goals

- No Docker-shaped `container commit` endpoint.
- No Compose service selection, Docker option parsing, or OCI image metadata.
- No claim that a no-freeze writable-filesystem snapshot is available.
