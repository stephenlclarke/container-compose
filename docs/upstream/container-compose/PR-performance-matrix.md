# Pull request: add the first Compose performance-matrix lane

## Summary

- Add `check-compose-performance-matrix.sh` for local, same-host, warm-image comparisons.
- Measure detached startup and `down --volumes --remove-orphans` teardown for 1, 10, and 50 independent services.
- Retain raw monotonic TSV samples, exact fingerprints, JUnit XML, and a Markdown median/P95 matrix.
- Add `make docker-compose-performance-matrix`, which uses the existing serialized local runtime wrapper.
- Update the parity ledger and review without overstating the remaining performance work.

Tracking record: [ISSUE-performance-matrix.md](ISSUE-performance-matrix.md).

## Type of change

- [x] New feature
- [x] Documentation update
- [ ] Breaking change

## Motivation and context

The parity goal requires a reproducible performance comparison against the pinned Docker Compose reference on the same Mac. Existing targeted checks captured useful timings but did not provide a common median/P95 format for the representative service-count lifecycle workloads. This change establishes that format without folding unmeasured logging, sync, or build work into a misleading aggregate.

## Functional parity and performance coverage

The generated fixtures use the same `alpine:3.20` image and independent `sleep` services in both lanes. Images are pulled before timing. Each timed command has a monotonic timeout and cleanup runs after every project. A fixture fails if either lane fails to complete or if the candidate median reaches the repository's established 10x material-regression guard.

The target reports P95 as the nearest-rank 95th-percentile sample, which is stable and transparent for the default five repetitions. The evidence is deliberately marked as warm-image and records that condition in `fingerprints.json`.

## Compatibility notes

- No Compose runtime semantics, Apple runtime APIs, package pins, or release artifacts change.
- The target is local-only and continues to acquire the shared macOS runtime lock through `run-with-container-runtime.sh`.
- The 10x executable threshold is not a comparable-performance claim; the ledger retains `PERF-003` until the remaining matrix lanes exist and measured paths meet the product criterion.

## Validation

```text
bash -n Tools/parity/check-compose-performance-matrix.sh
Tools/parity/check-compose-performance-matrix.sh --help
make -n docker-compose-performance-matrix
git diff --check
```

One local smoke completed one repetition through the normal runtime wrapper against the exact matched stack. It retained `.build/parity/performance-matrix-smoke/` with raw TSV, JUnit, the generated Markdown matrix, and fingerprints. The candidate was a debug build, so this is diagnostic evidence only: startup was 7.77×, 12.71×, and 14.69× Docker for 1, 10, and 50 services; teardown was 1.54×, 10.42×, and 26.14×. The four 10/50-service results exceed the repository's 10× guard. A matched non-debug, five-repetition run remains required before any performance claim.

## container-compose checks

- [x] Added a focused executable comparator.
- [x] Added or updated `STATUS.md`, the performance review, and paired handoff records.
- [x] Kept the change local-only and avoided Apple remotes.
- [x] Record a completed one-repetition debug diagnostic with retained artifacts.
- [ ] Record matched non-debug five-repetition release-grade evidence.
- [ ] Add attached/detached logs, `develop.watch` sync, and build-context lanes.
