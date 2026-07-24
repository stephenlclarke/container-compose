# Pull request handoff: consume Apple's builder race fix

## Summary

Refresh the exact Container dependency after Apple fixed the concurrent
BuildKit cold-start race in apple/container#2002. This is a pin-only Compose
source change: all builder behavior remains in the Apple-shaped Container
layer, while Compose continues to use its existing runtime abstraction and
build orchestration.

## Minimal integration boundary

- Changes no Compose command or configuration semantics.
- Adds no runtime workaround in `ComposeCore`.
- Pins the signed Container fork head in all three release authorities.
- Leaves Containerization and the immutable builder image unchanged.
- Updates only release/handoff documentation and the README divergence
  snapshot outside the exact pins.

## Code map

- `Package.swift`
  - resolves Container at `302e31e71821…`.
- `Package.resolved`
  - locks SwiftPM to the same immutable revision.
- `Tools/release/stack-refs.json`
  - makes packaging and stack-consistency checks use that revision.
- `README.md`
  - records zero upstream lag and the current fork head/count.
- `docs/upstream/container-compose/ISSUE-upstream-builder-race-sync-20260724.md`
  - records the upstream bug, dependency boundary, validation, and release
    impact.
- `docs/upstream/container-compose/PR-upstream-builder-race-sync-20260724.md`
  - provides this handoff.

## Validation

```sh
swift package resolve
make stack-consistency
make check
make coverage-check
make docker-compose-phase4-parity
```

Completed before handoff:

- exact dependency and stack consistency passed;
- release/CI/tooling checks passed;
- 1,118 Swift tests in 26 suites passed;
- Swift coverage is 91.38%;
- Go coverage is 90.06%.

The Phase 4 aggregate is the downstream live gate for annotations, exposed
ports, empty process overrides, state, events, and `up --exit-code-from`.

## PR template

### Type of change

- [x] Dependency refresh
- [x] Upstream bug fix consumption
- [x] Documentation update
- [ ] New Compose feature
- [ ] Breaking change

### Motivation and context

The stable release gate detected that Apple `container` advanced after the
previous Current build. Consuming the upstream race fix prevents concurrent
first builds from failing when another invocation wins BuildKit creation and
restores zero-lag upstream ancestry before Phase 4 is released.

### Testing

- [x] SwiftPM exact resolution
- [x] Stack consistency
- [x] Compose unit and coverage gates
- [ ] Live Phase 4 aggregate
- [ ] Docker Compose V2 parity
- [ ] Exact hosted CI, Sonar, Current, and stable release verification

### Reviewer notes

Review commit `e4144a7` as the complete code boundary. The Container source
change is separately reviewable at signed fork head `302e31e`. No Compose
runtime adapter or orchestration code changes in this refresh.

## Commit tracking

- Container fork head:
  `302e31e71821f5dd3b395da2f299fc42a5bd6150`.
- Compose pin:
  `e4144a71c43a62876a492c8c1b9e89ef04429989`.
