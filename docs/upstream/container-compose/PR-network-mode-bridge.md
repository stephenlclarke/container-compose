# Pull request: map Compose bridge mode to the built-in macOS network

## Summary

Implement the narrow, portable mapping for Docker Compose
`network_mode: bridge`: Container Compose now selects Container's built-in
`default` network rather than constructing a project-scoped default network.
The mapping stays in the Compose adapter because Container already exposes the
generic primitive.

## Constructible commit

- `998e45748b366a478d589bf12be839969d396967`
  `feat(network): map bridge network mode`

## Implementation

- `ComposeOrchestratorValidation` recognizes `bridge` alongside existing
  `none` and `host` modes.
- The command builder appends `--network default` before ordinary Compose
  network attachment creation, so `up`, `create`, and one-off `run` all select
  the same built-in runtime network.
- Orchestrator unit tests prove each command contains `--network default`,
  does not use `<project>_default`, and does not request a managed network.
- `check-compose-host-namespaces.sh` adds a `bridge` service and validates
  Docker Compose V2 config, optional daemon HostConfig, and container-compose
  dry-run output for both managed and one-off paths.
- `STATUS.md` records the exact default-bridge DNS and remaining namespace
  sharing boundaries.

## Verification

```sh
swift test --disable-automatic-resolution --filter \
  'ComposeOrchestratorTests.(upMapsNetworkModeBridgeToBuiltinRuntimeNetwork|createMapsNetworkModeBridgeToBuiltinRuntimeNetwork|runMapsNetworkModeBridgeToBuiltinRuntimeNetwork)'
make coverage-check
DOCKER_COMPOSE=docker-compose \
  CONTAINER_COMPOSE="$PWD/.build/debug/compose" \
  ./Tools/parity/check-compose-host-namespaces.sh --strict
git diff --check
```

The local Docker Compose 5.3.1 verification passes without a daemon for
configuration and dry-run parity. When a daemon is available, the same fixture
also verifies Docker's actual `HostConfig.NetworkMode` is `bridge`.

## Compatibility and risk

The change does not create a new network type or affect explicitly declared
Compose networks. It maps one Compose special value to one existing generic
runtime value. Docker's default bridge does not provide automatic service-name
DNS; therefore this slice correctly leaves source-scoped discovery and aliases
as separate runtime work instead of pretending that bridge mode solves them.
