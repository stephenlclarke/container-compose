# Packaging handoff: consume the Apple Container main sync

<!-- markdownlint-disable MD013 -->

## Problem

`container-compose` was pinned to Container revision
`a8f6cae4fc49f10dcfeb3241247ce82cef9c7749`. Apple Container main has since
advanced through `f4757afa`, and the downstream fork has integrated that
upstream history while retaining the fork's explicit Containerization and
builder-shim provenance.

Without a Compose provenance update, a local or packaged Compose build can
silently select the older runtime revision instead of the reviewed Apple main
sync.

## Required provenance update

- Pin the direct Container package dependency to
  `690ac0f77f0dcefade5b14868a197ff6c329e8f5`.
- Resolve `Package.resolved` from that exact remote revision.
- Record the same immutable revision in `Tools/release/stack-refs.json` so
  local builds, packages, and release validation select one runtime.

## Scope and ownership

This is a minimally invasive Compose-layer release-provenance update. The
Apple-shaped implementation remains in `stephenlclarke/container`; Compose
continues to own Docker-shaped translation, configuration, and parity tests.
No Apple source was changed for the dependency pin.

The upstream `containerization` commit `d9868bb6` (tmpfs pod support) is not
included: it is Phase 3 volume/mount work and stays deferred until the active
Phase 2 Current release has completed its seven-day soak on 2026-07-29.

## Commit tracking

- Container Apple-main merge:
  `599834f8b0692c30e5118c75df4b97f256e7f80d`
  (`merge: integrate apple main through f4757afa`).
- Container upstream handoff and fork provenance tip:
  `690ac0f77f0dcefade5b14868a197ff6c329e8f5`
  (`docs(upstream): hand off apple main sync`).
- Compose provenance update:
  `34ad28c15a062943a38f493d2f2ad1683fd55613`
  (`chore(deps): pin apple container main sync`).

## Validation

```sh
swift package dump-package
make stack-consistency
make check
make test
CONTAINER_STACK_REPO=/Users/sclarke/github/container \
CONTAINERIZATION_STACK_REPO=/Users/sclarke/github/containerization \
CONTAINER_BUILDER_SHIM_STACK_REPO=/Users/sclarke/github/container-builder-shim \
make docker-compose-parity
```

The live parity run used Docker Compose v2 `5.3.1`, the local Container binary
from the Apple-main sync, and the pinned Compose build. It completed all
declared targets and stopped the managed runtime.
