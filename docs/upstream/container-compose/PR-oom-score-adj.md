# Pull request: support Compose OOM score adjustment

## Summary

- Remove `oom_score_adj` from the unsupported-runtime ledger.
- Validate Linux scores from `-1000` through `1000` before runtime side effects.
- Map the value through typed service and healthcheck process configurations.
- Render the value for one-off `compose run` containers.
- Update parity status and the complete fork dependency pins.

## Commit tracking

- Containerization prerequisite: `1803d27` merged as
  `30abf67c05446a3030be836efd89e0c0da84d8fe` in
  `stephenlclarke/containerization`.
- Container runtime: `c4fa1ad` merged as
  `1ee6e51ca311366e930ed414d8b9dfff91ed51af` in
  `stephenlclarke/container`.
- Compose mapping: `feat/oom-score-adj` until this pull request is merged.

## Validation

```console
cd Tools/compose-normalizer && go test ./...
swift test --disable-automatic-resolution --filter 'ComposeOrchestratorTests' -Xswiftc -warnings-as-errors
make fmt
make check
make test
```
