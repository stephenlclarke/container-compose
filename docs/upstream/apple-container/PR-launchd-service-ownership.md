# Pull Request: reconcile stale launchd service ownership

## Summary

- Inspect a registered service's plist path through `launchctl print`.
- Reuse a stable service label only when its canonical plist owner matches the
  requested registration.
- Replace only a same-label service owned by another installation, and make
  API-server and plugin registration use that common reconciler.

## Intended Review Delta

Apply the signed commit
`7272c401bc134f67f64f50da5b6b5db922ebc6f7`
(`fix(launchd): reconcile stale service ownership`) from
`stephenlclarke/container`.

The change is limited to the existing macOS `ServiceManager` abstraction. It
does not add Compose-specific APIs, change Linux OCI guest semantics, or add
Windows support. The companion report is
[ISSUE-launchd-service-ownership.md](ISSUE-launchd-service-ownership.md).

## Code Map

- `Sources/ContainerPlugin/ServiceManager.swift`: derives a requested label,
  parses `launchctl print` ownership, canonicalizes plist paths, and chooses
  register, reuse, or scoped replace.
- `Sources/ContainerCommands/System/SystemStart.swift`: delegates API-server
  registration to the reconciler.
- `Sources/ContainerPlugin/PluginLoader.swift`: delegates plugin-helper
  registration to the same reconciler.
- `Tests/ContainerPluginTests/ServiceManagerTests.swift`: covers missing,
  matching, stale, and symlink-canonicalized ownership paths plus print
  parsing.
- `Tests/ContainerPluginTests/PluginLoaderTest.swift`: verifies delegation
  even when a matching label already exists.

## Validation

```console
swift test --filter ContainerPluginTests
make test SWIFT_TEST_FLAGS=--no-parallel
make coverage-unit SWIFT_TEST_FLAGS=--no-parallel
CONTAINER_STACK_REPO=/absolute/path/to/container make docker-compose-parity
```

The focused suite passes 55 tests. The full Container suite passes 1,119 tests
in 128 suites, and coverage exercises the registration-state branches. Live
macOS validation starts two distinct temporary application roots sequentially;
both starts succeed and `launchctl print` reports the second root's plist for
the API server, machine API, image helper, and default vmnet helper.

## Compatibility and Risks

- A repeated start from one application root reuses the existing services.
- A same-label service from another application root is intentionally replaced
  because its executable, environment, and data root are not compatible with
  the caller.
- The behavior is confined to launchd-managed services on macOS.

## Handoff Status

No Apple remote has been pushed. The downstream Compose dependency update must
pin the handoff tip after the source-matched parity suite passes.
