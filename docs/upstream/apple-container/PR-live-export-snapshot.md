# Add live filesystem snapshot export

## Summary

- Adds generic `container export --live` support for running containers.
- Freezes the root filesystem only long enough to copy its ext4 disk to a
  unique private temporary snapshot, then thaws it before archive export.
- Serializes the snapshot with lifecycle work and retries thaw on a failed
  copy, so a failed request does not leave the filesystem frozen.
- Keeps Docker Compose `commit` image shaping, service selection, and flags in
  `container-compose`.

## Upstream Context

- [apple/container#1400](https://github.com/apple/container/issues/1400)
- [apple/container#1630](https://github.com/apple/container/pull/1630)
- [apple/containerization#685](https://github.com/apple/containerization/pull/685)
- [apple/container#1762](https://github.com/apple/container/pull/1762) is not
  used: it adds Docker-shaped commit policy rather than this reusable runtime
  primitive.

## Implementation

- The CLI, client, XPC, and runtime service carry a typed `live` export mode.
- `ContainersService` accepts a running container only for that mode and uses a
  UUID-named temporary ext4 snapshot with deferred cleanup.
- The runtime freezes, copies, and thaws under the lifecycle lock. Copy errors
  execute a best-effort thaw before the original error is returned.
- Existing stopped and never-started export selection remains unchanged.

## Validation

```sh
make check
make test
CONCURRENT_TEST_SUITES='TestCLIExportCommand/' SERIAL_TEST_SUITES='NoSuchSuite/' make integration
```

The focused guest integration exercises actual running-container live export.
The unit suite passes 936 Swift Testing cases plus the XCTest suite.

## Commit Tracking

- Feature implementation: `7f9d739a0e312de1d474059aea55f23163d4a60e`
  (`feat(export): add live filesystem snapshots`) in `stephenlclarke/container`.
- Post-snapshot writability integration regression: `cf333204fc010893e118a10fcc87471059f4b211`
  (`test(export): verify live snapshots leave container writable`) in
  `stephenlclarke/container`.
- Fork review handoff: [stephenlclarke/container#5](https://github.com/stephenlclarke/container/pull/5).

## Remaining Limitation

This primitive supplies a brief filesystem-consistent freeze. It does not make
a safe no-freeze snapshot of a writable filesystem available, so Compose keeps
running `commit --pause=false` explicitly partial.
