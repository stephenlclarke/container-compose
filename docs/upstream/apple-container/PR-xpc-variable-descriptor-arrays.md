# Pull Request: preserve variable XPC descriptor arrays

## Summary

- Decode every descriptor actually present in an XPC array instead of assuming
  a two-descriptor regular-log response.
- Retain graceful `nil` handling for missing, malformed, or failed descriptor
  values without calling macOS XPC APIs out of bounds.
- Cover empty, one-, and two-descriptor responses plus a non-array value.

## Intended Review Delta

Apply the signed commit
`a8f6cae4fc49f10dcfeb3241247ce82cef9c7749`
(`fix(xpc): preserve variable descriptor arrays`) from
`stephenlclarke/container`.

The implementation is wholly inside the generic macOS XPC value decoder.
Compose remains an ordinary client and contains no workaround for one log
descriptor. The companion report is
[ISSUE-xpc-variable-descriptor-arrays.md](ISSUE-xpc-variable-descriptor-arrays.md).

## Code Map

- `Sources/ContainerXPC/XPCMessage.swift`: checks the XPC value type, iterates
  its actual array count, and returns the duplicated descriptors.
- `Tests/ContainerXPCTests/XPCClientTests.swift`: covers empty, one-, and
  two-element arrays and a non-array value.

## Validation

```console
swift test --filter ContainerXPCTests
make coverage
make check
CONTAINER_STACK_REPO=/absolute/path/to/container \
  CONTAINERIZATION_INIT_SOURCE_PATH=/absolute/path/to/containerization \
  make docker-compose-empty-process-overrides-parity
```

The focused XPC suite passes eight tests, including the one-descriptor
regression. Complete Container coverage passes 1,122 unit tests in 128
suites, 237 concurrent integration tests in 26 suites, and 143 serial
integration tests in 14 suites. The source-matched Compose v2 command is
recorded with the stack release validation.

## Compatibility and Risks

- Existing two-descriptor regular-log replies retain their ordering.
- One-descriptor follow-log replies now work without a macOS XPC API trap.
- Empty arrays remain representable; callers that require a descriptor keep
  their existing `first` or count validation.
- This is macOS-host XPC behavior only and adds no Windows path.

## Handoff Status

No Apple remote has been pushed. The Compose stack pin must include this
revision before source-matched parity and release validation.
