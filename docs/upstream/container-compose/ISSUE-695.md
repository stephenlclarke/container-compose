# Current publication rejects a stale Container dependency pin

## Problem

The exact-main Current package run for Compose revision `003a648fbced519a9f0d61c1b03ce1ee37b1481f` failed its release-configuration gate. `Tools/release/stack-refs.json`, `Package.swift`, and `Package.resolved` selected Container `272aeed9c70f79ddf69eb5826afdc96d8be4e3a7`, while the reviewed Container fork had advanced to `e54e1681eb713f6a9bce28afcc6877c67d5ba29a` through documentation and badge corrections.

The failure is intentional: a Current package must not claim a matched latest stack when one of its exact dependency identities differs from the sibling repository's `main` head. It nevertheless leaves the Prebuilt Binaries workflow red until Compose records the coherent dependency graph.

## Acceptance criteria

- `Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json` select the same exact Container revision.
- That revision equals `stephenlclarke/container` `main` when the change is prepared.
- SwiftPM resolves the graph without changing unrelated dependency pins.
- The generated README divergence snapshot reports the same Container head and current live ahead/behind counts.
- Stack consistency, Markdown, diff, pull-request review, and exact-head checks pass.
- Protected `main` completes exact runtime and SonarQube validation before the Current controller retries publication.

## Scope

This is dependency and release-authority maintenance. The selected Container commits after `272aeed9c70f` change documentation and workflow presentation, not runtime behavior. No Compose semantics, Docker parity claim, stable release, or stock-Apple dependency is changed.

## References

- [Pull request #695](https://github.com/stephenlclarke/container-compose/pull/695)
- [Failed exact-main package run](https://github.com/stephenlclarke/container-compose/actions/runs/35018887574)
- [Container documentation and badge reconciliation](https://github.com/stephenlclarke/container/pull/279)
