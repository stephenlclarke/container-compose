# Pull request: avoid an unread stdout pipe in health tests

## Summary

Remove a test-only helper that redirects process-wide stdout to an unread pipe
across asynchronous work. Run the two fallback-help commands directly under
their existing completion guard.

## Apple-shaped boundary

- Only `ApplicationHealthTests` changes.
- The local interception mechanism is removed rather than replaced.
- Existing completion assertions and the two-second wall timeout remain.
- No runtime binary, interface, stored state, or command output changes.

## Code map

- `Tests/ContainerCommandsTests/ApplicationHealthTests.swift` runs both help
  fallbacks directly, deletes `discardStandardOutput`, and removes `Darwin`.

## Testing

- [x] Five focused runs; 75 tests total
- [x] 1,131 instrumented unit tests in 131 suites
- [x] 38.69% unit line coverage report regenerated
- [x] `make check`
- [x] 3 warmup, 238 concurrent, and 143 serial integration tests
- [ ] Docker Compose V2 parity (downstream Compose pin)

## Compatibility and risk

The tests may emit a few help lines into captured test output. That is safer
than mutating a global descriptor across suspension points.

## Commit tracking

- `659a01733ac03c07624b545fb552f1536f80b203`
  (`test(health): avoid unread stdout pipe`)
