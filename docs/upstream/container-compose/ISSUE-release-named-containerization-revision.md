# Stable release helper rejects the current Container dependency shape

## Problem

The stable-release helper could update only a Containerization dependency whose
SwiftPM requirement contained an inline quoted revision:

```swift
.package(
    url: "https://github.com/stephenlclarke/containerization.git",
    revision: "..."
)
```

The current Container fork keeps the same fork-owned URL but stores the
revision in the package-level `containerizationRevision` constant. That
constant also feeds build provenance:

```swift
let containerizationRevision = "..."

.package(
    url: "https://github.com/stephenlclarke/containerization.git",
    revision: containerizationRevision
)
```

The first Phase 3 `0.8.0` promotion therefore stopped before committing,
pushing, or tagging, even though the revision already matched the validated
Containerization main.

## Reproduction

Run the release helper against the current matched stack:

```sh
CONTAINER_STACK_RELEASE_INTENT=milestone \
CONTAINER_STACK_MILESTONE_SOAK_OVERRIDE_REASON='explicit maintainer authorization' \
CONTAINER_STACK_RELEASE_PHASE5_BUILDER_GAPS_EXCEPTION_REASON='tracked Phase 5 Builder work' \
make release VERSION_SELECTOR=-+-
```

Before the correction, it reported:

```text
Package.swift is missing the stephenlclarke containerization dependency
```

## Required behavior

- Preserve support for inline quoted Containerization revisions.
- Recognize the exact fork dependency when its requirement references
  `containerizationRevision`.
- Update that named constant without rewriting the dependency declaration.
- Reject unrelated or Apple-upstream dependency URLs.
- Continue to resolve, validate, sign, and publish through the existing release
  gates.

## Acceptance criteria

- [x] A named revision constant updates to the requested 40-character SHA.
- [x] A literal revision continues to update.
- [x] An unsupported dependency fails closed.
- [x] The real current Container manifest accepts its already-matched revision
  without producing a diff.
- [x] The failed release attempt leaves no commit, pull request, or tag.

## Resolution

Implemented by
[`03f74ce997acc104135a7eecf76a9e0dc6edc78f`](https://github.com/stephenlclarke/container-compose/commit/03f74ce997acc104135a7eecf76a9e0dc6edc78f)
(`fix(release): update named runtime revisions`).
