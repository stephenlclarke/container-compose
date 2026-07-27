# Pull Request: use hashed build-context membership

## Summary

- Construct the existing `DirEntry` value for each archive candidate.
- Use `Set<DirEntry>.contains` instead of a closure-based linear scan.
- Preserve the existing `DirEntry` equality, hashing, and archive output.

## Intended Review Delta

Apply signed commit `41e31f7fe34e4a6a99ed9dd29512fd99a2cbc074`
(`perf(build): use hashed context membership`) from
`stephenlclarke/container`.

The companion report is
[ISSUE-build-context-membership.md](ISSUE-build-context-membership.md), and the
originating upstream report is
[apple/container#2022](https://github.com/apple/container/issues/2022).

## Code Map

- `Sources/ContainerBuild/BuildFSSync.swift`: replaces the closure scan in the
  tar filter with native hashed membership.

## Validation

```console
swift test --disable-automatic-resolution --filter BuildFSSyncTests
make coverage-unit
make check
CONTAINER_STACK_REPO=/absolute/path/to/container \
  CONTAINERIZATION_INIT_SOURCE_PATH=/absolute/path/to/containerization \
  make docker-compose-parity
```

The existing five focused `BuildFSSyncTests` pass with the hashed lookup.
Complete coverage and Compose v2 parity are required before publication.

## Compatibility and Risks

- The constructed entry uses the same URL, directory flag, and relative path
  represented by the selected set.
- The change relies on the existing `DirEntry` `Hashable` contract instead of
  adding a parallel path-only index.
- Archive ordering and contents are unchanged.
- No public API, Linux guest behavior, Windows path, or Compose-specific
  primitive changes.

## Handoff Status

No Apple remote has been pushed. This two-line implementation remains a
standalone reviewable commit.
