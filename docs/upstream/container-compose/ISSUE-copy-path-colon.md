# Bug: runtime copy paths with colons require a corrected Container revision

## Summary

The generic `container copy` CLI previously rejected legal guest paths with a
colon. `container-compose` has no Compose YAML `copy` key and does not render
copy commands, so it must not add an adapter workaround. It must instead
consume the fixed generic Container revision.

## Scope and non-goals

- Pin `container-compose` to the immutable generic runtime correction.
- Keep `Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json`
  in lockstep.
- Do not add a Docker Compose v2 fixture: Docker Compose has no service-level
  equivalent of `container copy`, so such a fixture would not test a valid
  Compose compatibility contract.

## Upstream context

The runtime defect is [apple/container#1969](https://github.com/apple/container/issues/1969).
The associated generic handoff is
[PR-copy-path-colon.md](../apple-container/PR-copy-path-colon.md).

## Commit tracking

- Required Container commit: `f03ae577d1c45e31ee6934cb020addb80334cf2d`
  (`fix(copy): preserve colons in container paths`)

## Validation expectations

- The release-stack consistency checker must accept one identical Container
  revision in every dependency declaration.
- Docker Compose v2 parity is explicitly not applicable because neither
  Compose YAML nor Docker Compose exposes a `copy` operation.
