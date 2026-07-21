# Compose compatibility gap: remaining project network options

## Compose surface

- networks.NETWORK_NAME.driver
- networks.NETWORK_NAME.attachable
- networks.NETWORK_NAME.enable_ipv4: false
- networks.NETWORK_NAME.ipam.options

The related enable_ipv6: false surface is implemented and recorded in [ISSUE-network-ipv6-auto.md](ISSUE-network-ipv6-auto.md).

## Docker Compose v2 behavior

The Compose specification exposes project network driver selection, standalone attachment, IP-family controls, and driver-specific IPAM options. Docker Compose preserves these fields in config. docker/compose issue 13785 tracks its current failure to pass ipam.options into Docker Engine network creation.

References:

- [Docker Compose issue 13785](https://github.com/docker/compose/issues/13785)
- [compose-go model PR 870](https://github.com/compose-spec/compose-go/pull/870)
- [Compose network reference](https://docs.docker.com/reference/compose-file/networks/)
- [Compose IPAM reference](https://docs.docker.com/reference/compose-file/networks/#ipam)

## Current container-compose behavior

The pinned compose-go dependency exposes these fields. The normalizer retains ipam.options in normalized, config, and convert output and deliberately does not pass them to vmnet, matching Docker Compose local-mode behavior.

The default bridge driver, attachable metadata, ordinary IPv4, one IPv6 subnet, and both enable_ipv6 values are supported. A disabled IPv6 network retains its Compose IPAM pool in the model but suppresses it from the effective generic create request, as documented in the dedicated IPv6 handoff.

Runtime-backed commands still reject custom drivers and enable_ipv4: false before network or service-container side effects. Those are the remaining behaviorally significant network-option gaps.

## Likely owner

container-compose owns the recognition and no-side-effects diagnostics. A future generic Apple primitive is needed only for IPv4 disablement or real custom driver selection. IPAM options remain inspection-only in the macOS local path and need no fabricated vmnet option.

## Validation

- Config output preserves ipam.options.
- Dry-run orchestration omits an invented vmnet IPAM option.
- IPv6 disablement is covered by the dedicated Compose and generic runtime integrations.
