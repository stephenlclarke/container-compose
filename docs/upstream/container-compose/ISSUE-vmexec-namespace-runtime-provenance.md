# Packaging handoff: Compose must consume the vmexec namespace-entry repair

## Problem

The checked Compose stack referenced earlier Container and Containerization
tips. A local Compose build could therefore omit the generic `vmexec` repair
that prevents Linux from returning `EINVAL` when execution targets the current
user namespace.

## Required provenance update

- Pin the direct Container dependency to
  `f4d5366f352ddbdc2ee13314a2183b89cd7a2f96`.
- Pin the direct Containerization dependency to
  `422302c9490f337ebfad0b17b9542de97bde9e34`.
- Resolve `Package.resolved` from those remote revisions and record the same
  refs in `Tools/release/stack-refs.json`.

## Scope

This is release provenance only. The generic guest fix belongs in
Containerization, Container consumes it without new API, and Compose retains
Docker-specific parsing, help, lifecycle semantics, and integration coverage.
No Current or stable release follows from the pin change alone.

## Commit tracking

- Containerization implementation:
  `fe896b6511d9fe0f0b8d3d25d3a8d8a1ed5ab5a1`.
- Containerization handoff tip:
  `422302c9490f337ebfad0b17b9542de97bde9e34`.
- Container provenance handoff tip:
  `f4d5366f352ddbdc2ee13314a2183b89cd7a2f96`.
- Compose provenance update:
  `dd0991a3344fc6cecc0c4b7e6cf756d52927f2b8`.
