# Pull Request: accept host user namespace mode

## Summary

This Compose-only slice accepts `userns_mode: host` and preserves it in
canonical config output. The local runtime already creates no OCI user
namespace, so the supported value truthfully selects the sandbox VM's existing
user namespace without adding a synthetic command-line flag.

## Implementation

- Preserve the Compose JSON key as `userns_mode` through the Go normalizer and
  Swift config renderer.
- Validate `host` as the sole supported value; reject `private` and custom
  mappings before resources are created.
- Add focused up/config tests, a Docker Compose V2 config/dry-run parity
  harness, and a live Compose YAML test for the guest UID map.

## Apple-Shaped Boundary

No Apple fork change is needed: this consumes the existing generic runtime
default. It introduces no Docker types into `apple/container`, no Windows
behavior, no macOS host user-namespace claim, and no fake UID/GID mapping.

## Verification

```sh
go test ./Tools/compose-normalizer/...
swift test --filter ComposeOrchestratorTests.upAcceptsHostUserNamespaceAsSandboxGuestDefault
swift test --filter ComposeOrchestratorTests.upRejectsPrivateUserNamespaceModeBeforeCreatingResources
swift test --filter ComposeOrchestratorTests.configPreservesHostUserNamespaceMode
CONTAINER_COMPOSE=/absolute/path/to/container-compose/.build/debug/compose DOCKER_COMPOSE=docker-compose ./Tools/parity/check-compose-userns-mode.sh --strict
```

The live runtime test additionally requires the matched local `container` stack
and runs with `CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1`.

## Remaining Gap

`userns_mode: private` and custom mappings remain unsupported until the runtime
can create and administer guest UID/GID mappings. This is intentionally not
emulated by the Compose layer.
