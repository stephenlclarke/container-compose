# Pull request: carry a Linux memory reservation to the runtime

## Intended delta

- Pin Containerization to the public OCI memory-reservation projection.
- Add optional `memoryReservationInBytes` to `LinuxRuntimeData` with
  backward-safe Codable handling.
- Apply it to `LinuxContainer.Configuration` before runtime-spec generation.
- Provide a `--memory-reservation` compatibility bridge with zero-as-default
  and signed-byte-range validation.

## Commit tracking

- Containerization prerequisite: `c5ca0366d88cf77eefb857b7b3d7f2d098070bab`.
- Stephen fork implementation: `089f55dbc3b85e814fc81464854852d887de86b9`.
- Stephen fork merge: `d5774583697dc239b140ae38cc79fa9259753061`.
- No Apple remote was modified.

## Upstream overlap review

No open `apple/container` issue or pull request matching `mem_reservation` was
found during the 2026-07-16 slice review.

## Validation

```console
make fmt
make check
make test
swift test --filter ParserTest/testMemoryReservation
swift test --filter ContainerRunCreateCommandTests/runtimeDataMemoryReservation
```
