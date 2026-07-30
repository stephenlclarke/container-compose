# Pull request: map Compose bridge mode to the built-in macOS network

## Summary

Implement the narrow, portable mapping for Docker Compose `network_mode: bridge`: Container Compose now selects Container's built-in `default` network rather than constructing a project-scoped default network. The mapping stays in the Compose adapter because Container already exposes the generic primitive.

## Constructible commit

- `f65f8b996619c8257b49a9ed86bc6571b12b2540` `feat(network): map bridge network mode`
- `570c93cc2d9d773e611c66b9c5d8966b142bf706` `fix(network): prevent unused bridge resources`
- `f146aa18a5b98a19b4654ccd45afb0ac949667ed` `fix(watch): remove async inout state`

## Implementation

- `ComposeOrchestratorValidation` recognizes `bridge` alongside existing `none` and `host` modes.
- The command builder appends `--network default` before ordinary Compose network attachment creation, so `up`, `create`, and one-off `run` all select the same built-in runtime network.
- Orchestrator unit tests prove each command contains `--network default`, does not use `<project>_default`, and does not request a managed network.
- `check-compose-host-namespaces.sh` adds a `bridge` service and validates Docker Compose V2 config and daemon `HostConfig`, container-compose config and managed/one-off dry-run output, and the live matched Apple runtime attachment.
- The live oracle verifies the runtime configuration and active attachment both name only `default`, and rejects any unexpected `<project>_default` network.
- Equivalent warm-image `up` and `down` operations record monotonic raw TSV timings, exact fingerprints, JUnit, and a Markdown matrix; timeout, incomplete execution, or a candidate median at least 10× Docker's corresponding median fails the check.
- Resource selection for `up` and `create` now provisions only networks and volumes referenced by the selected service plan. This prevents an unused project default network for `network_mode: bridge` and avoids equivalent unused-resource work for other selected-service operations.
- The existing watch loop now owns its mutable snapshot state locally instead of carrying an async `inout` coroutine across suspension points. Eight focused watch tests preserve behavior, and the ordinary Swift 6.3.3 release build no longer crashes in coroutine splitting.
- `STATUS.md` records the exact default-bridge DNS and remaining namespace-sharing boundaries.

## Verification

```sh
swift test --disable-automatic-resolution --filter \
  'ComposeOrchestratorTests.(upMapsNetworkModeBridgeToBuiltinRuntimeNetwork|createMapsNetworkModeBridgeToBuiltinRuntimeNetwork|runMapsNetworkModeBridgeToBuiltinRuntimeNetwork)'
make coverage-check
DOCKER_COMPOSE='docker compose' \
  CONTAINER_COMPOSE="$PWD/.build/debug/compose" \
  ./Tools/parity/check-compose-host-namespaces.sh --strict
CONTAINER_COMPOSE_LIVE=1 \
  CONTAINER_COMPOSE_CONTAINER=/path/to/matched/container \
  DOCKER_COMPOSE='docker compose' \
  ./Tools/parity/check-compose-host-namespaces.sh --strict
bash -n Tools/parity/check-compose-host-namespaces.sh
shellcheck Tools/parity/check-compose-host-namespaces.sh
git diff --check
```

Docker Compose 5.3.1 configuration and daemon inspection pass, as do container-compose configuration and dry-run checks. The live macOS run used release container-compose `f146aa18a5b98a19b4654ccd45afb0ac949667ed`, release Container `5119fea95e5c7820c4deceec75b59fadfa8f61c3`, and Containerization `971fc7e5e27467ebd6227e1ae54f3e5c23de87b4` on Mac17,9 with macOS 26.5.2.

The live oracle verified that runtime configuration and attachment contain exactly `default` and that no project-scoped default network exists. Five equivalent warm-image repetitions passed the performance gate:

| Operation | Docker Compose median | Container Compose median | Candidate/reference | Result |
| --- | ---: | ---: | ---: | --- |
| `network_mode: bridge` up | 0.153s | 1.131s | 7.41× | Pass |
| `network_mode: bridge` down | 10.182s | 5.768s | 0.57× | Pass |

The exact raw TSV, JUnit XML, runtime fingerprint JSON, and Markdown matrix remain in the ignored local evidence directory `.build/parity/host-namespaces-bridge-release-f146aa18/`.

## Compatibility and risk

The change does not create a new network type or affect explicitly declared Compose networks. It maps one Compose special value to one existing generic runtime value. Docker's default bridge does not provide automatic service-name DNS; therefore this slice correctly leaves source-scoped discovery and aliases as separate runtime work instead of pretending that bridge mode solves them.

## Primary references

- [Docker Compose `network_mode`](https://docs.docker.com/reference/compose-file/services/#network_mode)
- [Docker bridge network driver](https://docs.docker.com/engine/network/drivers/bridge/)
- [Apple Container DocC](https://apple.github.io/container/documentation/)
