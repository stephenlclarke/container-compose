# Feature request: carry a Linux memory-plus-swap limit to the runtime

## Summary

Expose an optional Linux memory-plus-swap limit through Container's typed
create/run configuration and preserve it in the Linux runtime request.

This follows the same generic split as memory reservation, but represents OCI
`LinuxMemory.swap`: the combined memory and swap cgroup limit. Compose syntax,
Docker flag compatibility, and policy validation remain outside Apple code.

## Generic behavior

- Carry an optional signed byte count in the Linux runtime payload.
- Assign it to `LinuxContainer.Configuration.memorySwapLimitInBytes` before
  OCI runtime-spec generation.
- Preserve an absent value for backward-compatible decoding and the runtime
  default.
- Preserve `-1` as the OCI unlimited-swap sentinel.
- Reject values that do not fit the OCI signed-byte representation before
  transport.

## Dependency and current fork state

The typed Containerization prerequisite is published as
[`06c00072bcb7868dcd1f3e378a7319faa00ae42c`](https://github.com/stephenlclarke/containerization/commit/06c00072bcb7868dcd1f3e378a7319faa00ae42c)
on `stephenlclarke/containerization` `main`. The matching Container transport
is published as
[`57cba8e39f5c0aa5d0a2566ff0e5187d9f63b105`](https://github.com/stephenlclarke/container/commit/57cba8e39f5c0aa5d0a2566ff0e5187d9f63b105)
on `stephenlclarke/container` `main`:

- `LinuxRuntimeData.memorySwapLimitInBytes` is optional and decodes missing
  values for wire compatibility.
- `RuntimeService` assigns that value to
  `LinuxContainer.Configuration.memorySwapLimitInBytes`.
- The generic `container create` and `container run` `--memory-swap` parser is
  a temporary local integration bridge. It accepts byte sizes, zero/unset, and
  `-1`, but intentionally does not implement Compose's `mem_limit` policy.

These two small lower-stack slices are now independently buildable and no
Apple pull request has been raised.

## Focused validation

```console
swift test --disable-automatic-resolution --filter '.*(MemorySwap|memorySwap).*'
```

The Container suite verifies byte parsing, the `-1` CLI sentinel, transport
encoding, and backward-compatible runtime-payload decoding.

## Upstream overlap review

No open `apple/container` issue or pull request matching `memory swap` was
found during the 2026-07-17 slice review.

## Apple-shaped split

Containerization owns OCI projection, Container owns transport to the runtime,
and Compose owns parsing plus the `mem_limit` relationship policy. The feature
does not call for a generic runtime interceptor: it is a small typed primitive
when the matched runtime lane needs it. No Apple remote was pushed.
