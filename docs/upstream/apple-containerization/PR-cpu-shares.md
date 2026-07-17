# Pull request: project Linux CPU-share weight

## Intended delta

- Add optional `cpuShares` to `LinuxContainer.Configuration`.
- Project it unchanged to `ContainerizationOCI.LinuxCPU.shares`.
- Add a runtime-spec regression test.

## Commit tracking

- Stephen fork implementation: `8e4cf75af5d828ce111474df956f3c5cf7407757`.
- Stephen fork merge: `d5e6c22d48cfea0fea0958b8079b7df3fb399a2a`.
- No Apple remote was modified.

## Upstream overlap review

No open `apple/containerization` issue or pull request matching `cpu_shares`
was found during the 2026-07-16 slice review.

## Validation

```console
make fmt
make check
make test
swift test --filter LinuxContainerTests/runtimeSpecIncludesConfiguredCPUShares
```
