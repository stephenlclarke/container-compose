# Pull Request: size resources outside service locks

## Summary

- Snapshot container and volume metadata while holding only the owning service
  lock.
- Remove the nested volume-lock/container-lock scope.
- Traverse resource trees on utility-priority detached tasks after locks are
  released.
- Derive active-volume counts from the same validated path snapshot used for
  filesystem sizing.
- Preserve total, active, and reclaimable disk-usage accounting.

## Intended Review Delta

Apply these signed commits from `stephenlclarke/container` in order:

1. `b15ac4aaf1ad7ce59a124c7e222a427565525d3a`
   (`perf(storage): size resources outside service locks`).
2. `c7d05f1e3396436d96090dbffc8f8196d34f3c1d`
   (`fix(storage): keep volume usage snapshots consistent`).

The companion report is
[ISSUE-disk-usage-lock-scope.md](ISSUE-disk-usage-lock-scope.md), and the
originating upstream report is
[apple/container#2022](https://github.com/apple/container/issues/2022).

## Code Map

- `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift`:
  snapshots identifier/status pairs and sizes validated paths off the actor.
- `Sources/Services/ContainerAPIService/Server/Volumes/VolumesService.swift`:
  snapshots store and mount metadata separately, then sizes validated paths
  off the actor and derives active count from that same path snapshot.
- `Tests/ContainerAPIServiceTests/DiskUsageConcurrencyTests.swift`: covers
  container and volume total, active, and reclaimable calculations against
  real temporary directory payloads.

## Validation

```console
swift test --disable-automatic-resolution --filter DiskUsageConcurrencyTests
make coverage-unit
make check
CONTAINER_STACK_REPO=/absolute/path/to/container \
  CONTAINERIZATION_INIT_SOURCE_PATH=/absolute/path/to/containerization \
  make docker-compose-parity
```

The two focused disk-usage regressions pass using real allocated-size results,
including a volume snapshot with fewer valid paths than total metadata entries.
The complete unit coverage gate passes 1,148 tests in 134 suites with 39.27%
line coverage. Compose v2 parity remains required before publication.

## Compatibility and Risks

- Total counts retain the metadata snapshot count even if an unsafe storage
  name is skipped, matching existing behavior.
- Running containers remain active; every other valid status remains
  reclaimable.
- Volume active count includes only mounted names present in the validated path
  snapshot. A stale or later mount reference cannot make active count exceed
  the snapshotted total.
- Filesystem traversal is still exact and synchronous within its detached
  utility task; only lock and actor occupancy change.
- No public API, Linux guest behavior, Windows path, or Compose-specific
  primitive changes.

## Handoff Status

No Apple remote has been pushed. The correction is isolated from the other
performance findings in `apple/container#2022`.
