# Process start observation should not add closure-depth debt

## Problem

The first exact-main SonarCloud analysis after child-process cancellation
reported three open maintainability issues in `ProcessRunner.swift`:

- `swift:S1186` required the intentionally empty production launch observer to
  explain why it has no body;
- two `swift:S3087` findings rejected launch-observer closures nested inside
  both a task-cancellation handler and checked continuation.

The exact analysis was
[`f1987b60-7da4-4ee8-941f-2094d4019eaf`](https://sonarcloud.io/project/activity?id=stephenlclarke_container-compose2&branch=main),
for revision
[`41d1e542ea3cbd83b27fb3ae0aab0a5bd857d706`](https://github.com/stephenlclarke/container-compose/commit/41d1e542ea3cbd83b27fb3ae0aab0a5bd857d706).
Its quality gate remained `OK`, but leaving new code smells open would make the
CC-002 handoff incomplete.

## Resolution

- Name the internal launch callback contract `ProcessStartObserver`.
- Move callback invocation into `notifyProcessDidStart`, outside the nested
  asynchronous continuation bodies.
- Keep the injected callback and cancellation behavior unchanged.
- Explain inside the production no-op observer that only tests install the
  launch-race hook.

## Apple-shaped boundary

This is a private Compose-layer maintainability correction. It changes no
public API, process lifecycle behavior, Apple runtime fork, Windows path, or
Docker-shaped runtime primitive.

## Acceptance

- The normal and ThreadSanitizer `ProcessRunner` suites remain green.
- The full Swift and Go coverage gate remains green.
- Docker Compose V2 and source-built YAML normalization semantics remain
  identical.
- SwiftFormat, strict SwiftLint, Markdownlint, and `git diff --check` pass.
- Exact-main SonarCloud reports gate `OK` with zero unresolved issues and
  hotspots.
