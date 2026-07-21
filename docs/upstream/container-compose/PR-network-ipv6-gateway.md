# Pull request: support Compose IPv6 IPAM gateways

## Summary

- Preserve a single IPv6 IPAM gateway through Compose normalization and the runtime-neutral resource boundary.
- Validate the gateway before side effects and reject a static service address that reuses it.
- Render `--gateway-v6` only for an enabled IPv6 network, while preserving disabled-network source metadata in `config`/`convert`.
- Add unit, macOS runtime, and Docker Compose v5.3.1 parity coverage.

## Type of change

- New feature
- Documentation update

## Motivation and context

Docker Compose supports an explicit gateway in an IPv6 IPAM pool. The Compose plugin previously preserved the subnet but rejected its gateway because the matched macOS runtime lacked a generic gateway primitive. The paired `apple/container` slice adds that focused, reusable vmnet capability; this Compose slice maps it without embedding Compose concepts in the Apple fork.

Docker Compose retains source IPAM data when IPv6 is disabled even though Docker Engine does not apply it. The adapter follows that split: configuration output keeps the declared subnet and gateway, while the effective runtime request drops both.

## Commit tracking

- Compose source and tests: signed [`134b2581`](https://github.com/stephenlclarke/container-compose/commit/134b25819f366f5fc44dc6b785406b481363a10e) (`feat(network): support IPv6 IPAM gateways`).
- Generic Apple-shaped fork source: signed [`c194d29`](https://github.com/stephenlclarke/container/commit/c194d298449ffbd0a8a30f3307e75900a0b11970) (`feat(network): add IPv6 gateway control`).
- Supporting Containerization API: [`fe272b2`](https://github.com/stephenlclarke/containerization/commit/fe272b22c133bd82e319d3c91863fe11abe708a0) (`feat(network): carry IPv6 on custom vmnet interfaces`).
- Generic-fork handoff: signed [`d19de8e`](https://github.com/stephenlclarke/container/commit/d19de8ec47dd08262616f29e37c7469b449102ce) (`docs(handoff): record IPv6 gateway support`).

## Implementation details

`Tools/compose-normalizer` emits the optional IPv6 gateway with the corresponding IPv6 subnet. `ComposeNetwork` and `ComposeNetworkCreateRequest` retain it through the Compose abstraction seam. The orchestrator validates it before creating a project resource, renders the generic CLI request deterministically, and suppresses IPv6 IPAM values when `enable_ipv6: false`. `ContainerClientResourceManager` then constructs only the generic `NetworkConfiguration` fields exposed by the matched Apple runtime.

## Docker Compose compatibility

Supported on macOS 26:

- Automatic IPv6 with `enable_ipv6: true`.
- One explicit IPv6 subnet and in-prefix gateway.
- `enable_ipv6: false` with source IPv6 subnet/gateway retained in configuration and omitted from runtime creation.

Not implemented:

- IPv6 allocation ranges, auxiliary addresses, or multiple IPv6 pools.
- `enable_ipv4: false`, embedded DNS, and service discovery.

## Validation

```sh
make go-test
make coverage-check
CONTAINER_COMPOSE_LIVE=1 make swift-runtime-test SWIFT_RUNTIME_TEST_FILTER='ComposeRuntimeTests.ComposeRuntimeSmokeTests/runtimeUpAppliesIPv6Gateway()'
make docker-compose-network-ipv6-parity CONTAINER_COMPOSE_LIVE=0
```

The checked-in tests cover the Go normalizer, Swift model and orchestrator seam, macOS runtime network inspection, the generic guest-route integration, and Docker Compose v5.3.1 configuration/dry-run parity. The local coverage gate passed 1,112 Swift tests with 91.39% Swift and 90.06% Go coverage.

## Compatibility and risks

- The new field is optional and preserves prior automatic `prefix + 1` gateway behavior when absent.
- A disabled IPv6 network continues to omit IPv6 runtime settings, avoiding a contradictory vmnet configuration.
- The change is macOS vmnet behavior only; Windows and Linux-host behavior are intentionally unchanged.

## Review checklist

- [ ] Confirm the paired Containerization and Container commits are signed and based on the current Apple upstream.
- [ ] Confirm the Compose and generic runtime tests pass against the same pinned stack.
- [ ] Confirm Docker Compose v2 parity passes with the supported reference version.
- [ ] Confirm `STATUS.md`, README, and the Apple handoff remain current.
