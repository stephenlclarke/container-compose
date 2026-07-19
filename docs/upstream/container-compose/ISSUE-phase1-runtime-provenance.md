# Release packaging gap: current stack omitted completed Phase 1 runtime work

## Problem

The Compose package graph and `Tools/release/stack-refs.json` still selected
Containerization `14e7957efc369507ff308c9217397c7ccca43445` and Container
`2e98e6090e4f06b4a93e5c29ad2de634e30e6f57`. Both revisions predate the
completed Phase 1 runtime provenance chain.

Consequently, a Current Compose release could report newer Compose behavior
while compiling against an older runtime graph. This is a packaging provenance
gap, not a change to Compose's public Docker-compatible surface.

## Required correction

- Pin Compose's Containerization package and lockfile to
  `2d7ae6c01227d4c95a5f44fdc9768070923ee335`.
- Pin Compose's Container package and lockfile to
  `bd436af1720d77599d56e3c5afe2ade4381f2ff1`.
- Record the same immutable revisions in the stack manifest and validate all
  package manifests and lockfiles with the strict consistency checker.
- Build the complete local stack from those revisions before publishing a new
  Current package.

## Apple-shaped boundary

Containerization owns the generic shared-sandbox namespace policy;
Containerization and Container contain no Docker or Compose type. Container
only pins the reviewed runtime revision. Compose remains the sole owner of
Docker Compose V2 normalization, validation, and policy decisions.

## Non-goals

- Enabling service/container namespace sharing. That remains unavailable until
  a durable generic Container sandbox-membership primitive exists.
- Adding a Compose syntax adapter or weakening an existing unsupported-field
  rejection.
- Windows compatibility or macOS host namespace access.

## Verification scope

The correction creates no new runtime branch. Existing Docker Compose V2
fixtures remain the behavior evidence for their respective features; this
slice validates remote resolution, strict stack consistency, compilation, unit
tests, and the matching macOS guest runtime integration without inventing a
new YAML parity claim.
