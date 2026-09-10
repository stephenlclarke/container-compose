# Issue 557: refresh corrected builder classification authority

## Problem

The recoverable 0.14.3 release preflight stopped before testing after Container
pull request #217 and container-builder-shim pull request #19 advanced their
fork heads. The reviewed Container builder-image pin
`25399784a692d5d5933ab3db67d385e0e82b5fad` and builder module-derived Go
toolchain fix `8538b2e7931f41a831af66dc65381f7acc46cc64` were not yet classified,
leaving both registries one commit short.

## Scope

- Classify both build fixes in their existing support-maintenance slices.
- Advance the exact Container and builder-shim fork heads.
- Refresh the README snapshot and human classification summary from the
  authoritative fetched repositories.
- Leave release assets, CodeQL, Homebrew, DocC, and released-artifact
  benchmarks to the retained 0.14.3 release transaction.

## Acceptance evidence

- `make fork-classifications-check` reports all 951 patch-unique non-merge
  commits classified exactly once.
- `make upstream-divergence-release-check` reports all three support forks
  current with Apple and cleanly mergeable.
- `make readme-upstream-metrics-check`, `make stack-consistency`, and
  `make upstream-handoff-registry-check` pass.
- Focused Markdown, JSON, and diff checks pass.
- Required pull-request checks pass on the exact head.

Related lower work: Container
[#216](https://github.com/stephenlclarke/container/issues/216) and
[#217](https://github.com/stephenlclarke/container/pull/217), and builder shim
[#18](https://github.com/stephenlclarke/container-builder-shim/issues/18) and
[#19](https://github.com/stephenlclarke/container-builder-shim/pull/19).

Implementation: [#558](https://github.com/stephenlclarke/container-compose/pull/558).
