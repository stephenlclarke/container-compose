# Feature request: project a Linux memory-plus-swap limit

## Summary

Expose an optional Linux memory-plus-swap limit on the public container
configuration and project it unchanged into OCI Linux memory resources.

OCI defines `LinuxMemory.swap` as the combined memory and swap cgroup limit.
This is a lower-runtime primitive; it contains no Docker or Compose parser,
CLI, or orchestration policy.

## Generic behavior

- Preserve an optional signed byte count on `LinuxContainer.Configuration`.
- Leave an absent value unset so the runtime keeps its normal swap policy.
- Project a positive value unchanged to the existing OCI `LinuxMemory.swap`
  field.
- Preserve `-1` as OCI's unlimited-swap sentinel.
- Use `Int64`, the range represented by OCI, so an out-of-range value is not
  silently converted or trapped during runtime-spec generation.

## Current fork representation

The isolated configuration-to-OCI projection and focused regression tests are
published as
[`06c00072bcb7868dcd1f3e378a7319faa00ae42c`](https://github.com/stephenlclarke/containerization/commit/06c00072bcb7868dcd1f3e378a7319faa00ae42c)
on `stephenlclarke/containerization` `main`. The matching Container transport
is published as
[`57cba8e39f5c0aa5d0a2566ff0e5187d9f63b105`](https://github.com/stephenlclarke/container/commit/57cba8e39f5c0aa5d0a2566ff0e5187d9f63b105)
on `stephenlclarke/container` `main`. This document remains their durable
Apple-shaped handoff while the Compose integration is reviewed.

## Focused validation

```console
swift test --disable-automatic-resolution --filter 'runtimeSpec.*MemorySwapLimit'
```

The focused suite verifies both a configured combined memory-and-swap limit and
OCI's `-1` unlimited-swap sentinel.

## Upstream overlap review

No open `apple/containerization` issue or pull request matching `memory swap`
was found during the 2026-07-17 slice review.

## Apple-shaped split

Containerization owns only the typed configuration-to-OCI projection. Container
must separately carry the value in its runtime request, and Compose owns
`memswap_limit` parsing and the Docker-compatible relationship validation with
`mem_limit`. This is a handoff document only: no Apple remote was pushed.
