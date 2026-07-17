# Pull request: expose OCI process OOM score adjustment

## Intended delta

- Add optional `oomScoreAdj` to `LinuxProcessConfiguration`.
- Pass the value unchanged to `ContainerizationOCI.Process`.
- Add a runtime-spec regression test.

## Commit tracking

- Stephen fork implementation: `1803d27`.
- Stephen fork merge: `30abf67c05446a3030be836efd89e0c0da84d8fe`.
- No Apple remote was modified.

## Validation

```console
make fmt
make check
make test
swift test --filter LinuxContainerTests/runtimeSpecIncludesConfiguredOOMScoreAdjustment
```
