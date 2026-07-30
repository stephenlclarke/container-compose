# Pull request: map Compose bridge mode to the built-in macOS network

## Summary

Implement the narrow, portable mapping for Docker Compose `network_mode: bridge`: Container Compose now selects Container's built-in `default` network rather than constructing a project-scoped default network. The mapping stays in the Compose adapter because Container already exposes the generic primitive.

## Constructible commit

Primary implementation:

- `36d81f70402c0d203bde8f7c8d57bb574a689e52` `feat(network): map bridge network mode`
- `d6b47233012a31be559c91f8e51f7a579a704736` `fix(network): prevent unused bridge resources`
- `d95194e4f573de9716316b4dc4c287f16e6deb2e` `fix(watch): remove async inout state`

Review, quality, and controlled-validation follow-through on the same branch:

- `98f2a7139b2e99a60cabdc8ca2d7190c33b7e994` `refactor(preflight): flatten signal handling`
- `35c2848ac37e8e5ad607b9b7662b396d1e6ef2b3` `chore(sonar): remove encoding warnings`
- `50a745c828e4b4b21f397cc5cf861674fe9911c2` `docs(handoff): record bridge network mode`
- `38308633055c77fc9cd244c313100c81617193b6` `docs(handoff): record live bridge parity`
- `9a95ec8cc5a84e15a187ff20ccf948e9ac14bfe9` `fix(ci): isolate container runtime validation`
- `4a2e0003496c9f96afcc0b3f3d54124ebc09b25b` `fix(runtime): recover interrupted XPC operations`

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

Docker Compose 5.3.1 configuration and daemon inspection pass, as do container-compose configuration and dry-run checks. The authoritative controlled full run used container-compose `4a2e0003496c9f96afcc0b3f3d54124ebc09b25b`, release Container `5119fea95e5c7820c4deceec75b59fadfa8f61c3`, and Containerization `971fc7e5e27467ebd6227e1ae54f3e5c23de87b4` on Mac17,9 with macOS 26.5.2. It verified that runtime configuration and attachment contain exactly `default`, that no project-scoped default network exists, and that all 62 maintained parity targets pass in 1,024.25s. Three equivalent warm-image repetitions produced:

| Operation | Docker Compose median | Container Compose median | Candidate/reference | Result |
| --- | ---: | ---: | ---: | --- |
| `network_mode: bridge` up | 0.151s | 1.101s | 7.30× | Pass |
| `network_mode: bridge` down | 10.179s | 5.969s | 0.59× | Pass |

A 10-repetition stress run recorded 0.156s/1.060s Docker/candidate `up` medians (6.78×) and 10.181s/5.924s `down` medians (0.58×), completing in 241.31s. The exact raw TSV, JUnit XML, runtime fingerprint JSON, matrices, and logs remain in `.build/parity/full-4a2e0003-controlled/` and `.build/parity/host-namespace-interrupted-delete-fix-rerun-2/`.

The bridge timings pass the explicit 10× executable guard, but the 7.30× startup result is not yet comparable to Docker Compose and remains part of `PERF-003`/`PERF-607`. Two SwiftNIO event-loop shutdown warnings during the image-volume Builder fixture did not fail any build or assertion and remain visible in the full log as backend cleanup evidence.

The controlled run also validated the CI reliability boundary. `Tools/ci/container-runtime-lock.sh` serializes cooperating users of the shared per-user launchd/XPC namespace, the harness reuses a retained exact init archive and proves API readiness, interrupted idempotent pulls retry once, and interrupted deletes require a confirmed absent postcondition. A non-cooperating devcontainer runner was quiesced for the authoritative window and restored immediately afterward.

## Compatibility and risk

The change does not create a new network type or affect explicitly declared Compose networks. It maps one Compose special value to one existing generic runtime value. Docker's default bridge does not provide automatic service-name DNS; therefore this slice correctly leaves source-scoped discovery and aliases as separate runtime work instead of pretending that bridge mode solves them.

## Primary references

- [Docker Compose `network_mode`](https://docs.docker.com/reference/compose-file/services/#network_mode)
- [Docker bridge network driver](https://docs.docker.com/engine/network/drivers/bridge/)
- [Apple Container DocC](https://apple.github.io/container/documentation/)
