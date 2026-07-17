# Pull request: carry a Linux memory-plus-swap limit to the runtime

## Intended delta

- Add an optional `Int64` `memorySwapLimitInBytes` to `LinuxRuntimeData`.
- Preserve absent fields when decoding older runtime requests.
- Assign the generic value to `LinuxContainer.Configuration` before OCI runtime-spec generation.
- Provide `container create/run --memory-swap` only as a small local compatibility bridge: zero is unset, `-1` is the OCI unlimited-swap sentinel, and other values must fit the signed OCI range.

## Non-goals

- No Compose parsing, Compose error messages, or `mem_limit` relationship policy.
- No generic runtime hook, interceptor, or provider framework.
- No VM cgroup scheduling changes beyond passing the existing OCI memory resource to the runtime.

## Commit tracking

- Containerization prerequisite: [`06c00072bcb7868dcd1f3e378a7319faa00ae42c`](https://github.com/stephenlclarke/containerization/commit/06c00072bcb7868dcd1f3e378a7319faa00ae42c) (`feat(runtime): project memory swap limit`) on `stephenlclarke/containerization` `main`.
- Container implementation: [`57cba8e39f5c0aa5d0a2566ff0e5187d9f63b105`](https://github.com/stephenlclarke/container/commit/57cba8e39f5c0aa5d0a2566ff0e5187d9f63b105) (`feat(runtime): carry memory swap limit`) on `stephenlclarke/container` `main`.
- No Apple remote was modified.

## Upstream overlap review

No open `apple/container` issue or pull request matching `memory swap` was found during the 2026-07-17 slice review.

## Validation

```console
swift test --disable-automatic-resolution --filter 'ParserTest/(testMemorySwapParsesDockerSentinelAndDefaults|testMemorySwapRejectsInvalidAndOutOfRangeValues)'
swift test --disable-automatic-resolution --filter 'ContainerRunCreateCommandTests/(runParsesMemorySwapFlag|createParsesUnlimitedMemorySwapFlag|runtimeDataEncodesMemorySwapFlag)'
swift test --disable-automatic-resolution --filter 'RuntimeConfigurationTests'
make check
```
