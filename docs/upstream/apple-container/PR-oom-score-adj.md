# Pull request: support process OOM score adjustment

## Intended delta

- Pin Containerization to its public OCI OOM-score projection.
- Add an optional `oomScoreAdj` to `ProcessConfiguration` with backward-safe
  Codable handling.
- Add `--oom-score-adj SCORE` to shared process flags.
- Carry the value through initial, healthcheck, exec, and machine runtime
  process projections.

## Commit tracking

- Containerization prerequisite: `30abf67c05446a3030be836efd89e0c0da84d8fe`.
- Stephen fork implementation: `c4fa1ad`.
- Stephen fork merge: `1ee6e51ca311366e930ed414d8b9dfff91ed51af`.
- No Apple remote was modified.

## Validation

```console
make fmt
make check
make test
swift test --filter ProcessConfigurationPrivilegeTests
swift test --filter ParserTest/testProcessOOMScoreAdjustmentFlag
```
