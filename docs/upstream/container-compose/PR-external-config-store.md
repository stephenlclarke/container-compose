# Pull Request: External Compose Configs Through Container Config Store

## Summary

- Resolve external Compose configs from the generic `container config` store.
- Stage returned bytes as private, read-only files for existing bind mounts.
- Preserve binary content, external `name:` resolution, and requested modes.
- Keep external secrets rejected until a purpose-built secure store exists.

## Intended Review Delta

- `stephenlclarke/container`
  `bc43e52b82dd5318e6c468aed761d837e4ef6196`
  `feat(config): add persistent config store`
- `container-compose`
  `a726ad06b35ca837badea912b7945f92c356f96b`
  `feat(configs): support external config stores`

Neither change is pushed to an Apple repository. The Apple-shaped backend
handoff is [PR-config-store.md](../apple-container/PR-config-store.md).

## Implementation Details

- Introduce `ContainerConfigReading` so orchestration depends on a small,
  injectable read interface instead of an on-disk store layout.
- Resolve a top-level external config's `name:` with the normalized naming rules
  used by other Compose resources.
- Materialize bytes below the project-private config/secret state root and mount
  them through the existing read-only bind-mount path.
- Do not write files or call the store during `--dry-run`.
- Reuse the existing project cleanup path during `down`.

## Compatibility And Limits

- Supported: external config grants for `up`, `run`, and `create`, including
  external `name:`, binary content, default targets, and Compose read-only mode.
- Not supported: external secrets, generated `uid`/`gid`, and live mutation of
  an already-consumed immutable config.
- Config updates follow immutable-resource semantics: delete and create the
  config, then recreate the service to consume its replacement.

## Validation

```sh
swift build --target ComposeCore
swift test --filter ExternalConfigOrchestratorTests
```
