# Pull Request: preserve equals signs in label values

## Summary

- Split generic labels once, at the key/value boundary.
- Preserve every later `=` in the value.
- Cover the parser and the real macOS `container run`/`inspect` path.

## Intended Review Delta

Apply `47c13a8ad0bf001fb569a17e73e2e3b8d4e45dff` from
`stephenlclarke/container`.

The change is restricted to `Parser.labels` and its tests. It introduces no
Compose model, Docker-specific type, or special-case parser.

## Upstream context

This resolves [apple/container#1977](https://github.com/apple/container/issues/1977).
The desired semantics match a first-separator key/value parse and are also
used for ordinary environment-file values.

## Code Map

- `Sources/Services/ContainerAPIService/Client/Parser.swift`: uses
  `maxSplits: 1` for labels.
- `Tests/ContainerAPIClientTests/ParserTest.swift`: verifies generic nested
  values and a routing-rule-shaped value.
- `Tests/IntegrationTests/Run/TestCLIRunCommand.swift`: verifies a live guest
  retains both values in its inspected configuration.

## Validation

```console
swift test --disable-automatic-resolution \
  --filter 'ParserTest/testLabelsPreserveEqualsInValues'
make test
make coverage-unit
make check
```

The focused parser test and the complete 1,113-test unit suite passed. Unit
coverage reported 38.03% line coverage (13,237 / 34,806). The integration test
is compiled and registered in the normal macOS integration suite. A local
source-matched `make install-kernel integration` attempt used a new isolated
app root, but its apiserver readiness check timed out before a guest could be
created; the test service was stopped immediately. Run the committed
integration test on a healthy macOS Virtualization/XPC runner before offering
this upstream.

## Handoff Status

No Apple remote has been pushed. The Stephen-owned fork commit is ready for
Apple-maintainer review once the live integration rerun is green.
