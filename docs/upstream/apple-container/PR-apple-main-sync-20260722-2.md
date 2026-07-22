# Pull request: synchronize Apple test fixtures

## Summary

Merge `apple/container` through `f0b2b96`, adopt its typed warmup fixture and
compatible Collections lock, and retain the fork's explicit stack provenance.

## Apple-shaped boundary

- One signed merge commit retains Apple parentage.
- Conflict resolution is limited to the fixture API and dependency source.
- Fork-only tests use Apple's `WarmupImage` abstraction rather than adding a
  parallel fixture mechanism.
- No Compose types, flags, or runtime behavior are introduced.

## Code map

- `Package.resolved` adopts Apple’s 1.5.1 Collections resolution while keeping
  the fork Containerization source.
- `Tests/ContainerCommandsTests/TestCLIRunInitImage.swift` uses `WarmupImage`
  and retains deterministic invalid-image coverage.
- Seven fork-only integration tests replace removed array subscripts with
  `.alpine320`.

## Testing

- [x] `make check`
- [x] 1,131 instrumented unit tests in 131 suites
- [x] 38.69% unit line coverage report regenerated
- [x] 3 warmup, 238 concurrent, and 143 serial integration tests
- [ ] Docker Compose V2 parity (downstream Compose pin)

## Commit tracking

- `3cab3a085a472057f3dd54c391cc4fd5c41fe36a`
  (`chore(upstream): sync Apple test fixtures`)
