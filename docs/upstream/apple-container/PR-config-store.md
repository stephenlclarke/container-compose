# Apple PR Handoff: Persistent Non-Secret Config Store

## Summary

Add a persistent, immutable configuration resource to `container` with a
public XPC client, server implementation, and `container config` command group.

## Intended Review Delta

- `bc43e52b82dd5318e6c468aed761d837e4ef6196`
  `feat(config): add persistent config store`

The commit is in the `stephenlclarke/container` fork only. It is not pushed to
an Apple repository.

## Changes

- Add `ConfigConfiguration`, `ConfigResource`, storage, and typed errors.
- Persist metadata through `FilesystemEntityStore` and bytes in a sibling
  `content` file below the API server config root.
- Add XPC create, delete, list, inspect, and explicit read routes.
- Add `ClientConfig` as the public consumer API.
- Add `container config create|list|inspect|read|delete` for provisioning and
  inspection.
- Add path-safety, persistence, byte-round-trip, duplicate, empty-content, and
  concurrent-create coverage.

## Design Notes

This is a resource-management primitive, not Compose integration. It knows no
Compose project, service target, or Docker output policy. `container-compose`
consumes `ClientConfig.read` and stages a private read-only bind mount.

Content is omitted from `list` and `inspect`; consumers must request `read`
explicitly. This reduces routine accidental disclosure but does not claim
secret-grade protection.

## Security Boundary

This feature is for public/non-secret configuration such as application
settings, policy files, and generated config fragments. Passwords, tokens,
private keys, and certificates need a separate secure-store design.

## Validation

```sh
swift test --filter 'ConfigValidationTests|ConfigsServiceTests|StoragePathTests'
swift build --target ContainerCommands --target container-apiserver
container config --help
```

## Follow-Up Consumer

`container-compose` can support external `configs` after this backend is
available. External `secrets` intentionally remain partial pending a secure
store.
