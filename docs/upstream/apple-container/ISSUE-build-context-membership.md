# Performance: build-context archive membership scans a set linearly

## Summary

`BuildFSSync.tar` stores selected build-context entries in a `Set<DirEntry>`,
but its archive filter previously searched that set with a closure comparing
`relativePath`. This discarded the set's hashed lookup and made each candidate
membership check linear in the number of selected entries.

This reproduces the second performance finding in
[apple/container#2022](https://github.com/apple/container/issues/2022).

## Reproduction on macOS

1. Create a build context with a large number of selected files.
2. Run `container build`.
3. Profile the archive filter in `BuildFSSync.tar`; each candidate iterates the
   `Set` until a matching relative path is found.

## Expected behavior

Construct the equivalent `DirEntry` for each archive candidate and use native
`Set.contains`, retaining the existing equality and hashing contract.

## Ownership and boundary

This is generic build-context archive construction in `apple/container`.
Compose should continue to submit ordinary concurrent build requests without a
second context index.

## Commit tracking

- `41e31f7fe34e4a6a99ed9dd29512fd99a2cbc074` —
  `perf(build): use hashed context membership`.

## Validation expectations

- Preserve included, ignored, re-included, directory, and synthetic
  Dockerfile behavior in the existing `BuildFSSyncTests`.
- Run the complete Container unit and coverage gates.
- Retain Docker Compose v2 build-context parity.
