# Recoverable build workflow timings — 9 September 2026

## Scope

These are diagnostic wall-clock timings from the first real run of the native
Make, SwiftPM, and Go build controller on the development Mac. They measure
build-system behaviour, not application runtime performance. The retained
JSONL records are under the controller's protected external state root.

The previous Nextflow evidence included source checks and test suites as well
as builds, so its 9 minute 23 second repository profile is not a like-for-like
cold-build baseline. It must not be used to claim a build speed-up.

## Build timings

The corrected cold five-repository build completed in 292.726 seconds:

- `container-builder-shim`: 0.394 seconds.
- `container-engine-api`: 31.678 seconds.
- `containerization`: 56.770 seconds.
- `container`: 154.122 seconds.
- `container-compose`: 74.460 seconds.

The independent builder, engine API, and Containerization roots ran in
parallel, so their durations do not sum to the end-to-end result. Bin-path
queries added 1.196 seconds in total.

An immediate unchanged rerun verified and reused all five exact pins in 5.873
seconds. That recovery path was 49.8 times faster than the cold build and
removed 286.853 seconds, or 98.0%, from the end-to-end duration.

The initial pre-fix run stopped after 225.619 seconds when SwiftPM found that
Compose and Container required different exact Containerization revisions.
The successful upstream pins were retained. The fix replaced mutable SwiftPM
edit sessions with identity-preserving local manifest overrides, and a
targeted regression now enforces that hand-off.

## Test timings

The targeted build-controller regression suite ran five tests in 10.578
seconds. The wider exact-head controller review ran 57 relevant tests in
24.437 seconds.

The complete Python tooling gate ran before the timing exercise and took
1,215.05 seconds wall time:

- Coverage tools: 7 tests.
- Release tools: 515 tests in 727.433 seconds.
- CI tools: 304 tests in 470.572 seconds.
- Nested stack self-tests: 25 tests in 14.969 seconds.

The release gate remains the authority for full product, parity, security, and
documentation validation. Those release-only timings will be retained by its
own checkpoint evidence rather than mixed into this build-only measurement.
