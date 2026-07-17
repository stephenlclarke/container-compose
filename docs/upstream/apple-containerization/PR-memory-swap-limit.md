# Pull request: project a Linux memory-plus-swap limit

## Intended delta

- Add optional signed `memorySwapLimitInBytes` to `LinuxContainer.Configuration`.
- Preserve absent values for the runtime default and `-1` for OCI's unlimited-swap sentinel.
- Project the value unchanged to existing `LinuxMemory.swap` when generating the OCI runtime specification.

## Non-goals

- No Docker or Compose parser, CLI, validation, or defaulting policy.
- No Container service transport code.
- No unrelated memory-resource or cgroup scheduling changes.

## Commit tracking

- Containerization implementation: [`06c00072bcb7868dcd1f3e378a7319faa00ae42c`](https://github.com/stephenlclarke/containerization/commit/06c00072bcb7868dcd1f3e378a7319faa00ae42c) (`feat(runtime): project memory swap limit`) on `stephenlclarke/containerization` `main`.
- Container transport: [`57cba8e39f5c0aa5d0a2566ff0e5187d9f63b105`](https://github.com/stephenlclarke/container/commit/57cba8e39f5c0aa5d0a2566ff0e5187d9f63b105) (`feat(runtime): carry memory swap limit`) on `stephenlclarke/container` `main`.
- Compose policy is a separate follow-on change.
- No Apple remote was modified.

## Upstream overlap review

No open `apple/containerization` issue or pull request matching `memory swap` was found during the 2026-07-17 slice review.

## Validation

```console
swift test --disable-automatic-resolution --filter 'LinuxContainerTests/(runtimeSpecIncludesConfiguredMemorySwapLimit|runtimeSpecPreservesUnlimitedMemorySwapLimit)'
make check
```
