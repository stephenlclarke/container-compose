# Map Docker Compose `network_mode: bridge` to the macOS runtime default network

## Problem

Docker Compose V2 accepts `network_mode: bridge` as the Docker built-in bridge network. Container Compose parsed that portable service value but rejected it as an unsupported network mode, even though the macOS Container runtime already has an equivalent built-in generic network named `default`.

The missing behavior is a narrow Compose adapter mapping, not an Apple runtime primitive. It must not be confused with custom named network modes or `network_mode: service:NAME`/`container:NAME`, which require a different network-namespace lifecycle.

## Acceptance criteria

- Accept `network_mode: bridge` for `up`, `create`, and one-off `run`.
- Emit exactly `container --network default` and create no project-scoped Compose network for that service.
- Retain Compose V2 `config` parity for the `bridge` value.
- Preserve the diagnostic boundary for `service:NAME`, `container:NAME`, and arbitrary custom network names.
- State that the default bridge has no Compose service-name DNS, matching Docker's default-bridge behavior and the existing macOS runtime boundary.
- Cover direct orchestrator commands, normalized configuration, managed and one-off dry-run paths, Docker daemon inspection, and live matched-runtime inspection.
- Retain monotonic raw timings, JUnit evidence, exact runtime fingerprints, and a human comparison matrix for equivalent warm-image bridge lifecycle operations.
- Fail performance parity only on timeout, incomplete execution, or a candidate median at least 10× the corresponding Docker Compose median.

## Scope and compatibility

This is Compose-layer-only and works on macOS with the existing Container runtime. It changes no fork and introduces no Linux-only or Windows behavior. It intentionally does not claim source-scoped discovery, aliases, attachable networks, custom drivers, or shared network namespaces.

## Acceptance evidence

The live macOS oracle passed on 2026-07-30 using the release builds from container-compose `f146aa18a5b98a19b4654ccd45afb0ac949667ed`, Container `5119fea95e5c7820c4deceec75b59fadfa8f61c3`, and Containerization `971fc7e5e27467ebd6227e1ae54f3e5c23de87b4`. Docker Compose 5.3.1 and Docker Engine 29.2.1 were the same-host reference on an Apple silicon Mac17,9 running macOS 26.5.2.

The runtime configuration and active attachment both contained only the built-in `default` network. Neither lane created an unused project default network for the bridge-only timed service.

Five warm-image repetitions produced these medians:

| Operation | Docker Compose | Container Compose | Candidate/reference | Result |
| --- | ---: | ---: | ---: | --- |
| `network_mode: bridge` up | 0.153s | 1.131s | 7.41× | Pass |
| `network_mode: bridge` down | 10.182s | 5.768s | 0.57× | Pass |

The ignored local evidence directory retains the raw monotonic TSV, JUnit XML, runtime fingerprints, and Markdown matrix under `.build/parity/host-namespaces-bridge-release-f146aa18/`.

## References

- [Docker Compose `network_mode`](https://docs.docker.com/reference/compose-file/services/#network_mode) defines `bridge` as Docker's default bridge rather than the project network and explicitly excludes service-name resolution.
- [Docker's bridge driver documentation](https://docs.docker.com/engine/network/drivers/bridge/) distinguishes the daemon's default bridge from user-defined bridge networks.
- [Apple Container DocC](https://apple.github.io/container/documentation/) documents the Container client and network service APIs; the pinned CLI additionally exposes `container run --network <name>` and the built-in `default` network used by this adapter.
