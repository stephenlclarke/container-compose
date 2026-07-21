# Pull request: retain local Compose IPAM options for inspection

## Summary

- Preserve project network ipam.options through compose-go normalization and config or convert output.
- Keep IPAM options inspection-only on the local vmnet path, matching Docker Compose local-mode behavior.
- Continue early rejection for custom drivers and enable_ipv4: false.
- Record the later IPv6-disablement primitive as a completed adjacent capability rather than an unresolved IPAM-options gap.

## Motivation and context

compose-go exposes IPAM options in the typed model. Docker Compose preserves those options in configuration and tracks [docker/compose issue 13785](https://github.com/docker/compose/issues/13785) for engine forwarding. The macOS vmnet backend has no equivalent generic driver-options contract, so forwarding a fabricated option would be misleading.

## Commit tracking

- Original Compose IPAM-options implementation: [7040b19e554fa1d01baa0b8a4c1242b53552ea94](https://github.com/stephenlclarke/container-compose/commit/7040b19e554fa1d01baa0b8a4c1242b53552ea94), fix(network): retain local IPAM options.
- IPv6-disablement follow-up: [d49c2505a8c7536388b3fd8f996c94bdc1f56013](https://github.com/stephenlclarke/container-compose/commit/d49c2505a8c7536388b3fd8f996c94bdc1f56013) and [4bce15d507837e3f8bb58ebc4efd557a283bff82](https://github.com/stephenlclarke/container/commit/4bce15d507837e3f8bb58ebc4efd557a283bff82).
- The generic IPv6 handoff is [PR-network-ipv6-disablement.md](../apple-container/PR-network-ipv6-disablement.md).

## Current compatibility

Supported:

- Default bridge behavior, ordinary IPv4, one IPv6 subnet, attachable metadata, and inspection-only IPAM options.
- enable_ipv6 true with automatic or explicit IPv6 allocation.
- enable_ipv6 false with or without a declared IPv6 IPAM subnet.

Remaining gaps:

- Custom drivers and enable_ipv4 false remain rejected before side effects.
- IPv6 gateway, allocation range, auxiliary addresses, and multiple same-family pools are outside this IPAM-options slice.

## Validation

    make go-test
    make swift-test
    make docker-compose-network-ipam-options-parity
    make docker-compose-network-ipv6-parity CONTAINER_COMPOSE_LIVE=0
