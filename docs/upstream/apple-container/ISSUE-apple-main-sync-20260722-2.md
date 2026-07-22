# Synchronize Apple test fixtures through `f0b2b96`

## Context

Apple merged two maintenance commits after the fork's previous synchronization:

- `968dbe4` restores the compatible `swift-collections` 1.5.1 resolution.
- `f0b2b96` replaces an untyped warmup-image array with `WarmupImage`.

The matched Compose stack must consume those upstream contracts without losing
its source-pinned Containerization dependency or fork-only macOS regressions.

## Required behavior

- Merge Apple `main` through `f0b2b96` without rewriting Apple history.
- Preserve the fork's Containerization source and Builder provenance.
- Use `.alpine320` in the seven fork-only tests affected by the typed fixture.
- Keep deterministic invalid-image construction in the init-image rejection
  test instead of treating a valid warmup fixture as invalid.
- Make no Compose policy or public runtime change in the synchronization.

## Validation

- `make check` passed.
- The synchronized source passed 1,123 tests before later slice work.
- The final tree passed 1,131 instrumented unit tests in 131 suites and
  regenerated the unit report at 38.69% line coverage.
- The source-build integration gate passed 3 warmup tests, 238 concurrent tests
  in 27 suites, and 143 serial tests in 14 suites on the MacBook Pro.

## Commit tracking

- `3cab3a085a472057f3dd54c391cc4fd5c41fe36a`
  (`chore(upstream): sync Apple test fixtures`)
