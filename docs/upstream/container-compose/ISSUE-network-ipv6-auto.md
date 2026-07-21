# Compose compatibility: IPv6 network address assignment

## Compose surface

- networks.NETWORK_NAME.enable_ipv6

## Docker Compose v2 behavior

Docker Compose accepts both boolean values in normalized configuration. A true value enables IPv6 address assignment; a false value disables it. Configuration output retains a declared IPv6 IPAM pool even when IPv6 is disabled. Docker Engine ignores that IPv6 pool during network creation.

References:

- [Compose networks reference](https://docs.docker.com/reference/compose-file/networks/#enable_ipv6)
- [Compose IPAM reference](https://docs.docker.com/reference/compose-file/networks/#ipam)

## Current container-compose behavior

container-compose accepts enable_ipv6: true with or without an explicit IPv6 IPAM subnet. vmnet assigns a prefix when the enabled path has no explicit subnet.

container-compose also applies enable_ipv6: false on macOS 26. Its normalized config and convert model retain a declared IPv6 pool for Docker Compose compatibility. The runtime request carries the disabled setting but deliberately suppresses that pool before constructing the generic NetworkConfiguration: a direct generic request cannot simultaneously disable IPv6 and select an IPv6 subnet. The resulting vmnet network disables NAT66 and router advertisements and reports no IPv6 subnet.

## Ownership and handoff

container-compose owns Compose YAML normalization, Docker-compatible config and dry-run output, and the decision to retain only model metadata that the effective macOS network create cannot use.

The generic macOS primitive is owned by apple/container. It is represented by the Apple-shaped fork commit [4bce15d507837e3f8bb58ebc4efd557a283bff82](https://github.com/stephenlclarke/container/commit/4bce15d507837e3f8bb58ebc4efd557a283bff82) and the paired [Apple handoff](../apple-container/ISSUE-network-ipv6-disablement.md). The Compose implementation is [d49c2505a8c7536388b3fd8f996c94bdc1f56013](https://github.com/stephenlclarke/container-compose/commit/d49c2505a8c7536388b3fd8f996c94bdc1f56013).

Windows-specific networking is out of scope.

## Validation

- Go normalizer tests cover enabled, disabled, and disabled-with-pool models.
- Swift unit tests cover normalization, dry-run rendering, request forwarding, and the generic adapter.
- A macOS runtime smoke test brings up a Compose YAML project with enable_ipv6: false and an IPv6 pool, then confirms the realized network has enableIPv6 false and no IPv6 subnet.
- The focused generic CLI integration creates a network with --disable-ipv6 and confirms the persisted configuration and vmnet status.
- Tools/parity/check-compose-network-ipv6.sh compares both values with local Docker Compose v5.3.1.

## Remaining macOS gaps

IPv6 gateways, allocation ranges, auxiliary addresses, and multiple IPv6 pools remain unsupported. This slice does not implement embedded DNS or service discovery, and enable_ipv4: false remains a separate runtime gap.
