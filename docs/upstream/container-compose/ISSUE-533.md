# Issue 533: refresh 0.14.3 upstream alignment metadata

## Problem

The 0.14.3 stable-release preflight stopped before any build because the reviewed fork-classification authority still named the pre-`use_api_socket` Container head and the previous Apple Containerization head. The Container fork has since added its reviewed unattended Engine API dependency pin at `228897171d71975988ccdc690f1982e7433952af` and durable Engine socket grant at `40ab92d74a02bbd6b7436a50d47c38898a4bc294`. Apple Containerization added Pi agent support at `847655d373a27b8b8d0c3a9747f04f16b5de1206`, and the support fork synchronized that change unchanged at `f9d57ad1c80944c43bec6fc74afe1bfac3956480`.

## Scope

- Classify the two new patch-unique Container commits in their existing reviewed maintenance and generic-runtime slices.
- Advance the exact Container and Containerization fork heads and Apple Containerization head.
- Refresh the README snapshot and human classification summary from the authoritative fetched repositories.
- Leave release-version prose, stack dependency pins, and generated release documents to the recoverable 0.14.3 release transaction because their focused consistency checks remain green at the current source checkpoint.

## Acceptance evidence

- `make fork-classifications-check` reports all 948 patch-unique non-merge commits classified exactly once.
- `make upstream-divergence-release-check` reports all three support forks current with Apple and cleanly mergeable.
- `make readme-upstream-metrics-check`, `make stack-consistency`, and `make upstream-handoff-registry-check` pass.
- Focused Markdown, JSON, and diff checks pass.
- Exact-head review has no unresolved findings and the required pull-request checks pass.

Related lower work: Container [#208](https://github.com/stephenlclarke/container/pull/208) and [#213](https://github.com/stephenlclarke/container/pull/213), and Containerization [#77](https://github.com/stephenlclarke/containerization/pull/77).

Implementation: [#534](https://github.com/stephenlclarke/container-compose/pull/534).
