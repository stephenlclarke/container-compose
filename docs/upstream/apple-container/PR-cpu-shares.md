# Pull request: carry a Linux CPU-share weight to the runtime

## Intended delta

- Pin Containerization to the public OCI CPU-share projection.
- Add optional `cpuShares` to `LinuxRuntimeData` with backward-safe Codable
  handling.
- Apply it to `LinuxContainer.Configuration` before runtime-spec generation.
- Provide a `--cpu-shares` compatibility bridge with zero-as-default and
  minimum-nonzero-weight validation.

## Commit tracking

- Containerization prerequisite: `d5e6c22d48cfea0fea0958b8079b7df3fb399a2a`.
- Stephen fork implementation: `d1f3aee65f3f53d959825ef91d99ccbedf3492f9`.
- Stephen fork merge: `0c80ec848da79747f0c2c0c121d85f9876d6b919`.
- Follow-up implementation: `f4af7bc8e18dac2f356e4530f24af1efd35a914f`.
- Follow-up fork merge: `4b567a52b626fa6d3d786dc545e4f9d905f33bce`.
- No Apple remote was modified.

## Upstream overlap review

No open `apple/container` issue or pull request matching `cpu_shares` was found
during the 2026-07-16 slice review.

## Validation

```console
make fmt
make check
make test
swift test --filter ParserTest/testCPUSharesAcceptsValidValues
swift test --filter ContainerRunCreateCommandTests/runtimeDataOmitsDefaultCPUSharesFlag
```
