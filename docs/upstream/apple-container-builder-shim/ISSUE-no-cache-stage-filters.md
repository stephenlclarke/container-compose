# Preserve named no-cache stage filters

## Problem

The Builder metadata protocol already uses the Dockerfile frontend
`no-cache` key. An empty value means all stages, while a comma-separated value
selects named Dockerfile stages. The shim previously reduced key presence to a
Boolean and later wrote an empty value, so `base,compile` became an all-stage
cache miss.

This prevented Docker Compose `build.no_cache_filter` and
`docker compose build --no-cache-filter` from retaining their selected stages
through the macOS Builder boundary.

## Expected behavior

- Omitted metadata must omit the Dockerfile frontend attribute.
- Present empty metadata must preserve the existing all-stage behavior.
- Present non-empty metadata must reach BuildKit unchanged.
- Repeated metadata must retain the protocol's existing last-value rule.
- No Compose-specific model or path may be added to the generic shim.

## Proposed implementation

Represent `BOpts.NoCache` as an optional string and emit that optional value
from `dockerfileFrontendAttrs()`. This keeps the current metadata and BuildKit
frontend boundary and avoids a new protocol field.

The focused implementation is the signed commit
`af599a5c9cae51d7625da57d2220bd913f60d4a1`
(`feat(build): preserve no-cache stage filters`).

## Acceptance criteria

- [x] Unit tests cover absent, empty, named-stage, and repeated metadata.
- [x] Existing all-stage `--no-cache` behavior remains unchanged.
- [x] Full Go tests, lint, build, coverage, and license checks pass.
- [x] The immutable current image is published with a recorded digest.
- [x] Docker Compose V2 and matching macOS runtime integration pass.

## Validation evidence

- Repository tests, lint, build, and license checks: passed.
- Repository statement coverage: 44.5%.
- Merged fork commit:
  `f97cddf5b3aae2426a094613793c11c41b1d2e53`.
- Current image:
  `ghcr.io/stephenlclarke/container-builder-shim/builder:current-30068004175-f97cddf5b3aa`.
- Image digest:
  `sha256:d993210e3960bce33a84e061d6cb96385b43277fe94a7492fd6c60b6317d2197`.
- Manifest prerelease:
  `builder-current-30068004175-f97cddf5b3aa`.
