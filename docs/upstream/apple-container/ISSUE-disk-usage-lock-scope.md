# Performance: disk usage walks filesystems while service locks are held

## Summary

Container and volume disk-usage calculations previously traversed every
resource directory while holding service locks. Volume sizing also nested its
volume lock around a container-list lock. Large sparse or populated resource
trees could therefore delay unrelated create, list, or lifecycle operations.

This reproduces the fourth performance finding in
[apple/container#2022](https://github.com/apple/container/issues/2022).

## Reproduction on macOS

1. Create containers or volumes with large on-disk trees.
2. Invoke `container system df`.
3. Concurrently perform an operation requiring the container or volume service
   lock.
4. The operation waits for synchronous allocated-size traversal to complete.

## Expected behavior

Snapshot only the in-memory resource metadata under service locks, release the
locks, and perform synchronous filesystem traversal on a utility-priority
detached task. Derive active-volume accounting from the same validated path
snapshot used for sizing so a concurrent attachment cannot make the active
count exceed the total count. Preserve total, active, and reclaimable
accounting.

## Ownership and boundary

This is generic macOS host storage accounting in the
`ContainerAPIService`. Compose should not cache or recreate the runtime's disk
usage model.

## Commit tracking

- `b15ac4aaf1ad7ce59a124c7e222a427565525d3a` —
  `perf(storage): size resources outside service locks`.
- `c7d05f1e3396436d96090dbffc8f8196d34f3c1d` —
  `fix(storage): keep volume usage snapshots consistent`.

## Validation expectations

- Cover running and stopped container accounting with known on-disk payloads.
- Cover active and unused volume accounting with known on-disk payloads.
- Preserve the total metadata count while deriving active and reclaimable
  counts from validated snapshotted paths when an invalid identifier is
  skipped.
- Cover a simulated post-snapshot volume attachment and prove active count
  cannot exceed the snapshotted total.
- Run the complete Container unit and coverage gates.
- Confirm Compose v2 resource-model parity remains unchanged.
