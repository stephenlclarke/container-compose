# Pull request: project a Linux memory reservation

## Intended delta

- Add optional `memoryReservationInBytes` to `LinuxContainer.Configuration`.
- Project it unchanged to `ContainerizationOCI.LinuxMemory.reservation`.
- Add runtime-spec regression coverage for the maximum OCI-safe value.

## Commit tracking

- Stephen fork implementation: `bfd6c0da31391e32d531db53cc8df56cbd4810ac`.
- Stephen fork range-safety fix: `b0614cbf986dcca48183aa1ff0e4df8561302c85`.
- Stephen fork merge: `c5ca0366d88cf77eefb857b7b3d7f2d098070bab`.
- No Apple remote was modified.

## Upstream overlap review

No open `apple/containerization` issue or pull request matching
`mem_reservation` was found during the 2026-07-16 slice review.

## Validation

```console
make fmt
make check
make test
swift test --filter LinuxContainerTests/runtimeSpecIncludesConfiguredMemoryReservation
```
