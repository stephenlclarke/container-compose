# Issue 434: pin the serialized Containerization NBD test

## Problem

Stable 0.14.1 validation exposed a concurrency-sensitive Containerization
integration test: the NBD format-and-persist case can collide with neighboring
NBD tests when Swift Testing runs the suite concurrently. The runtime behavior
is correct in isolation, but the nondeterministic test schedule prevents the
matched release stack from completing reliably.

## Resolution

Consume the reviewed Containerization serialization fix through Container
pull request [#194](https://github.com/stephenlclarke/container/pull/194), then
pin both immutable support-fork revisions in Compose.

The lower-level fix is tracked by Containerization issue
[#65](https://github.com/stephenlclarke/containerization/issues/65) and pull
request [#66](https://github.com/stephenlclarke/containerization/pull/66).

## Acceptance criteria

- `Package.swift`, `Package.resolved`, and the release stack manifest agree.
- The fork metrics and commit-classification evidence describe the same heads.
- The Compose stack-consistency, fork-classification, and README metric checks
  pass before release validation resumes.
- Stable 0.14.1 validation runs the corrected exact-head stack.
