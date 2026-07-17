# Pull Request: External Compose Secrets Through Local Secret Store

## Summary

- Resolve top-level external Compose secrets from `ClientSecret`.
- Stage returned binary bytes under the existing project-private secret root.
- Reuse read-only bind mounts, Compose `external.name`, target paths, and
  generated file modes.
- Keep secret values out of command arguments, labels, and diagnostic output.

## Intended Review Delta

- `stephenlclarke/containerization`
  `9f63d1890ebbb999f552e88124cbcc6e7813e631`
  generic Keychain password primitive
- `stephenlclarke/container`
  `468a85e233dd9ee71897adfada3d812d1da0d4cf`
  local opaque secret store
- `stephenlclarke/container-compose`
  external-secret materialization follow-up

Neither backend change is pushed to an Apple repository. The Apple-shaped
handoffs are [PR-keychain-generic-password.md](../apple-containerization/PR-keychain-generic-password.md)
and [PR-secret-store.md](../apple-container/PR-secret-store.md).

## Implementation Details

- Introduce `ContainerSecretReading`, allowing orchestration tests to inject a
  reader and keeping Compose independent of a storage layout.
- Read external values only when executing a non-dry-run lifecycle action.
- Materialize each value into a private `0700` project directory with the
  requested read-only mode, then mount it at Docker-compatible secret paths.
- Use the same project cleanup path as all generated configs and secrets.
- Surface lookup failures by Compose source and resolved runtime name without
  including value bytes.

## Compatibility And Limits

- Supported: `external: true` secrets, optional external `name:`, binary
  content, default and explicit targets, and Compose read-only mode.
- Generated `uid`/`gid` ownership is supported by the owned-file snapshot
  follow-up. Live mutation of an already-consumed immutable secret remains
  unsupported.
- Secret values require a local Keychain session accessible to the Compose
  caller; they are intentionally not delegated to an XPC server.

## Validation

```sh
swift build --target ComposeCore
swift test --filter ExternalConfigOrchestratorTests
```
