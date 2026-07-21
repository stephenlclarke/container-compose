# Pull request: support Compose IPv6 network disablement

## Summary

- Preserve both enable_ipv6 boolean values and a disabled network's IPv6 IPAM pool in config and convert output.
- Pass the value through the runtime abstraction.
- Render --disable-ipv6 and omit --subnet-v6 from the effective macOS create plan when IPv6 is disabled.
- Add an Apple-shaped generic network primitive in the container fork for disabling NAT66 and router advertisements.
- Cover the model, direct adapter, dry-run plan, live macOS runtime, generic CLI, and Docker Compose v5.3.1 parity.

## Type of change

- New feature
- Documentation update

## Motivation and context

The prior Compose slice correctly accepted automatic IPv6 enablement, but could not honor enable_ipv6: false because vmnet had no generic disable control. Silently accepting a disable request would leave IPv6 active. The new primitive supplies the smallest reusable macOS mechanism while leaving Compose-specific parsing, model retention, and Docker-shaped execution policy in container-compose.

Docker Compose keeps an IPv6 IPAM pool in configuration when enable_ipv6 is false. The effective Docker network create does not use that pool. container-compose follows that distinction: it preserves the model for config and convert, then omits the contradictory pool from the generic vmnet request.

## Commit tracking

- Compose source and tests: [d49c2505a8c7536388b3fd8f996c94bdc1f56013](https://github.com/stephenlclarke/container-compose/commit/d49c2505a8c7536388b3fd8f996c94bdc1f56013), feat(network): support IPv6 disablement.
- Generic Apple-shaped fork source: [4bce15d507837e3f8bb58ebc4efd557a283bff82](https://github.com/stephenlclarke/container/commit/4bce15d507837e3f8bb58ebc4efd557a283bff82), feat(network): add IPv6 disablement control.
- Apple handoff: [PR-network-ipv6-disablement.md](../apple-container/PR-network-ipv6-disablement.md).
- Earlier automatic-enable correction: [55d00074864d21c70c9b03995886fbc9cf9e57de](https://github.com/stephenlclarke/container-compose/commit/55d00074864d21c70c9b03995886fbc9cf9e57de).

## Implementation details

The Go normalizer exports enableIPv6 as an optional boolean. ComposeNetwork and ComposeNetworkCreateRequest retain that value through the Swift boundary. The direct adapter maps a missing value to the existing enabled default. A false value maps to the generic enableIPv6 control and clears only the runtime IPv6 subnet. Dry-run output mirrors that execution request.

The generic fork uses a typed Boolean in NetworkConfiguration with a backward-compatible Codable default. The API service and helper pass the setting to vmnet, where false disables NAT66 and router advertisements before startup and avoids publishing an IPv6 prefix.

## Docker Compose compatibility

Supported on macOS 26:

- enable_ipv6: true with an explicit IPv6 subnet.
- enable_ipv6: true without a subnet, using vmnet automatic allocation.
- enable_ipv6: false with or without a declared IPv6 IPAM subnet.

Not implemented:

- IPv6 gateway, allocation range, auxiliary addresses, or multiple IPv6 pools.
- enable_ipv4: false.
- Embedded DNS and service discovery.

## Validation

    make go-test
    make swift-test
    make coverage-check SWIFT_COVERAGE_MIN=90 GO_COVERAGE_MIN=90
    make docker-compose-network-ipv6-parity CONTAINER_COMPOSE_LIVE=0

The slice passed Swift coverage 91.46 percent, Go coverage 90.10 percent, the focused generic macOS CLI integration, the focused Compose runtime YAML integration, and Docker Compose v5.3.1 parity locally.

## Handoff status

- The Compose and fork branches contain signed, independently reviewable commits.
- No Apple-owned remote has been pushed.
- The fork delta is generic and contains no Compose parser, label, project-name, or Docker output policy.
