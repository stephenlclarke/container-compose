# Compose compatibility gap: byte-precise `mem_limit`

## Compose surface

`services.<name>.mem_limit` accepts Compose byte values such as
`209715201b`. The value must reach the generic runtime as the exact byte
count, without an intermediate mebibyte conversion.

## Docker Compose V2 behavior

Docker Compose V2 preserves a byte-granular service memory limit in
`config --format json` and accepts the same value for local `up`:

```yaml
services:
  api:
    image: alpine:3.20
    mem_limit: 209715201b
```

The Docker Compose V2 configuration model contains `mem_limit: 209715201`.

## Previous container-compose behavior

The Compose normalizer already retained the exact byte value. The generic
`container run/create --memory` parser, however, converted the value through
an integral MiB representation. That silently lost the final byte before the
Apple guest runtime received the memory limit.

## Ownership and minimal implementation

This is a generic parser precision correction in the Apple-shaped `container`
fork plus a small Compose parity fixture. It creates no Compose-specific API.

- `stephenlclarke/container` commit
  `e2ac60b4d8c14813abc8779ee9d1246078c8040e` keeps explicit and default
  `--memory` values in bytes through configuration projection.
- `containerization` already models memory as bytes, so no source or pin
  change is needed there.
- `container-compose` commit
  `c94dc4f42cd6377af2ed01ae3312a77962661447` adds byte-precise normalizer and
  Docker Compose V2 parity coverage and records the corrected support status.
- `container-compose` commit
  `da649c62b8e086bdb2356c2cadecbcf7df1a894c` pins the replayed Container
  commit for the tested release stack.

The fork delta is limited to generic CLI parsing and its existing resource
configuration projection. The Compose repository owns the Compose-file
contract, status register, and parity fixture.

## Scope and non-goals

- Apply exact hard memory limits to Linux guest containers running on macOS.
- Preserve values with a `b` unit and defaults through the generic CLI path.
- Confirm Docker Compose V2 config parity and local Compose command rendering.
- Do not add Windows resource behavior.
- Do not claim fractional CPU quota, cgroup controls, swap tuning, or live
  Docker Engine validation where the local Mac has no daemon.

## Expected behavior

- Both Compose implementations normalize the fixture to `209715201` bytes.
- `container-compose --dry-run up --no-start` renders
  `--memory 209715201` for the service container.
- `container run/create --memory 209715201b` preserves exactly 209,715,201
  bytes in the runtime configuration.

## Upstream handoff condition

The `container` implementation is a pushed, Apple-shaped fork commit replayed
onto the current `fork/main` base. Before opening an upstream PR, rerun its
focused parser/resource/runtime tests and `make check` on the final base; if
the fork advanced, replay only this code commit and refresh this handoff.
