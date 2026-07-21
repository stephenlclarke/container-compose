# Pull Request: isolate quiet machine-list integration expectations

## Summary

- Make the quiet machine-list integration test assert that its own ID is
  present instead of assuming the shared runtime has no other machines.
- Preserve the actual quiet-output contract by asserting that no table header
  is emitted.

## Intended Review Delta

Apply the signed commit
`e36445bff4ff764d51e0349d9fa799906e953976`
(`test(machine): isolate quiet machine listings`) from
`stephenlclarke/container`.

The delta is restricted to the existing macOS machine integration test. It
does not change a runtime API, Compose mapping, Linux guest behavior, or any
Windows path. The companion report is
[ISSUE-machine-list-quiet-test-isolation.md](ISSUE-machine-list-quiet-test-isolation.md).

## Code Map

- `Tests/IntegrationTests/Machine/TestCLIMachineRuntimeSerial.swift`: split
  quiet-list output into lines, require the test-owned machine ID, and reject
  a `NAME` table header without constraining unrelated valid entries.

## Validation

```console
CONTAINERIZATION_INIT_SOURCE_PATH=/absolute/path/to/containerization \
  make integration CONCURRENT_FILTER='TestCLIMachineRuntimeSerial/testListQuietMode' \
  SERIAL_FILTER='NoMatchingIntegrationTest'
make check
CONTAINERIZATION_INIT_SOURCE_PATH=/absolute/path/to/containerization make coverage
```

The targeted integration reproduces the former multi-machine condition and
passes with the unrelated machine retained. The complete coverage run passes
1,120 unit tests in 128 suites, 237 concurrent integration tests in 26 suites,
and 143 serial integration tests in 14 suites.

## Compatibility and Risks

- The production `machine ls -q` output is unchanged.
- The test still rejects table-formatted output through the header assertion.
- Other installations and developer-created machines are no longer treated as
  test artifacts.

## Handoff Status

No Apple remote has been pushed. The downstream Compose stack pins this commit
for source-matched validation.
