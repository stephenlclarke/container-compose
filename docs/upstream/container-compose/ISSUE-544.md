# Issue 544: refresh 0.14.3 Container classification authority

## Problem

The stable 0.14.3 release preflight correctly stopped before expensive testing after Container pull request #215 advanced the fork from `40ab92d74a02bbd6b7436a50d47c38898a4bc294` to `aaacb3ed973f9e47434fc14335f87a4a42a1f2ad`. The reviewed dependency-pin commit `09acdc2f1df2d8a15a37e6dbce19dbf94ed2a607` was not yet classified, leaving the registry at 665 of 666 current fork-only commits.

## Scope

- Classify the new Container dependency pin in the existing support-maintenance slice.
- Advance the exact Container fork head.
- Refresh the README snapshot and human classification summary from the authoritative fetched repositories.
- Leave release-version prose, release assets, CodeQL, Homebrew, DocC, and released-artifact benchmarks to the recoverable 0.14.3 release transaction.

## Acceptance evidence

- `make fork-classifications-check` reports all 949 patch-unique non-merge commits classified exactly once.
- `make upstream-divergence-release-check` reports all three support forks current with Apple and cleanly mergeable.
- `make readme-upstream-metrics-check`, `make stack-consistency`, and `make upstream-handoff-registry-check` pass.
- Focused Markdown, JSON, and diff checks pass.
- Exact-head review has no unresolved findings and the required pull-request checks pass.

Related lower work: Container [#214](https://github.com/stephenlclarke/container/issues/214) and [#215](https://github.com/stephenlclarke/container/pull/215).

Implementation: [#545](https://github.com/stephenlclarke/container-compose/pull/545).
