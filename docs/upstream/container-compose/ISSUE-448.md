# Issue 448: pin synchronized Container fork for 0.14.1

## Problem

The 0.14.1 stable preflight correctly stopped after Apple `container` advanced.
Container issue 199 and pull request 200 synchronize the support fork with
Apple's read-only clean repair and current release-action pin. Compose must use
that reviewed merge and refresh its exact release evidence before promotion.

## Scope

- Pin Container merge `2647090a8af74cf18fae2472342cdb55bab60e45` in
  SwiftPM and the release stack manifest.
- Refresh the fork classification registry and current upstream snapshot.
- Preserve the reviewed 0.14.1 logging, runtime reliability, benchmark, and
  workflow corrections.
- Run focused consistency and classification validation locally, followed by
  exact-head review and hosted checks.

## Acceptance evidence

- The Swift manifest, lockfile, release stack manifest, README snapshot, and
  classification registry agree on immutable heads.
- Focused stack, classification, metric, handoff, Markdown, and diff checks
  pass.
- Exact-head review has no unresolved findings and required hosted checks pass.

Related lower work: Container [#199](https://github.com/stephenlclarke/container/issues/199)
and [#200](https://github.com/stephenlclarke/container/pull/200).
