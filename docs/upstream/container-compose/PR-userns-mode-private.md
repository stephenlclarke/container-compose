# Pull request: support private user namespace mode

## Summary

Adds Docker Compose V2-compatible `userns_mode: private` support. `host`
remains the sandbox VM's existing user namespace; `private` creates an
identity-mapped namespace inside that guest.

## Constructible commits

- Containerization prerequisite:
  `943f95fb7a338a04a4831d98a845a5a90d07f864`
  `feat(runtime): add private guest user namespaces`
- Container prerequisite:
  `1081cb565b41918fa8f7c26c7c9559b31014a211`
  `feat(runtime): add private guest user namespace mode`
- Compose implementation:
  `e007611a9b3411aadc8a537d7d5afb143af6d493`
  `feat(runtime): support private user namespace mode`
- Compose unsupported-mode coverage:
  `2df2f4061e1a63385e48e7d2eb060d7bf021d74b`
  `test(runtime): reject unsupported user namespace modes`

## Implementation

- `Sources/ComposeCore/ComposeOrchestratorRuntimeSupport.swift` accepts
  `host` and `private`, maps only `private` to a runtime argument, and rejects
  other values.
- `Sources/ComposeCore/ComposeOrchestratorRunCopyStart.swift` forwards
  `--userns private` only when requested.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` covers command and
  canonical-config behavior.
- `Tests/ComposeRuntimeTests/ComposeRuntimeSmokeTests.swift` starts a YAML
  service with `userns_mode: private` and reads its guest UID map.
- `Tools/parity/check-compose-userns-mode.sh` compares `host` and `private`
  config output and dry-run acceptance with Docker Compose V2.

## Runtime boundary

Compose owns Docker-shaped parsing, diagnostics, and command construction. The
fork patches remain generic OCI/runtime slices. The live harness builds and
selects a matching guest `vminitd` image because an older guest image predates
the map handshake.

## Verification

```sh
go -C Tools/compose-normalizer test ./...
swift test --filter PrivateUserNamespace
swift test --filter ComposeOrchestratorTests.upRejectsUnsupportedUserNamespaceModeBeforeCreatingResources
make docker-compose-userns-mode-parity DOCKER_COMPOSE_REFERENCE=docker-compose
make swift-runtime-test \
  SWIFT_RUNTIME_TEST_FILTER=ComposeRuntimeSmokeTests.runtimePrivateUserNamespaceHasIdentityMappedGuestNamespace
```

The focused Swift tests, matched guest-image YAML test, and Docker Compose
5.3.1 config parity check passed locally. The Docker daemon was unavailable,
so the parity harness correctly skipped only Engine dry-run confirmation.

## Compatibility and remaining gap

`host` and omission remain unchanged. `private` is an identity-mapped guest
namespace (`0 0 4294967295`); it does not expose a macOS host namespace.
Custom/named user namespace mappings remain unsupported.
