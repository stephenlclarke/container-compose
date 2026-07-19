# Compose compatibility gap: explicit IPv6 disablement

## Compose surface

- `networks.<name>.enable_ipv6`

## Docker Compose v2 behavior

Docker Compose accepts both boolean values in normalized config. `true` asks
the network implementation to assign IPv6 addresses; `false` asks it not to.

```yaml
services:
  api:
    image: alpine:3.20
    networks:
      - backend
networks:
  backend:
    enable_ipv6: true
```

References:

- Compose networks reference: <https://docs.docker.com/reference/compose-file/networks/#enable_ipv6>
- Compose IPAM reference: <https://docs.docker.com/reference/compose-file/networks/#ipam>

## Current container-compose behavior

The Compose-only slice
[`55d00074864d21c70c9b03995886fbc9cf9e57de`](https://github.com/stephenlclarke/container-compose/commit/55d00074864d21c70c9b03995886fbc9cf9e57de)
accepts `enable_ipv6: true` with or without an explicit IPv6 IPAM subnet. The
generic vmnet network-create path automatically assigns a prefix when no subnet
is supplied, and `up` creates a network whose runtime status has a non-empty
`ipv6Subnet`.

vmnet exposes no control that suppresses this automatic allocation. The
normalizer therefore reports `enable_ipv6: false` as unsupported and Compose
rejects it before network or service-container side effects. This is deliberate:
silently accepting a request to disable IPv6 would be incorrect.

This change does not implement embedded DNS, service-name discovery, or any
other network feature beyond the IPv6 assignment result.

## Likely owner

`container-compose` owns the typed Compose normalization, pre-side-effect
diagnostic, Docker Compose V2 parity fixture, and runtime integration test.

An Apple-shaped `container` API is needed only to close the remaining gap: a
generic network configuration control that can suppress automatic IPv6 address
allocation and reports the resulting state. No fork change is justified for
the accepted `true` path because the existing generic vmnet behavior already
provides its required result. Windows-specific networking is out of scope.

## Code handoff

- Normalization: `Tools/compose-normalizer/main.go`,
  `projectNetworkValues`.
- Go coverage: `Tools/compose-normalizer/main_test.go`.
- Swift normalizer coverage:
  `Tests/ComposeCoreTests/ComposeNormalizerTests.swift`.
- macOS runtime integration:
  `Tests/ComposeRuntimeTests/ComposeRuntimeSmokeTests.swift`.
- Docker Compose V2 parity harness:
  `Tools/parity/check-compose-network-ipv6.sh` and the
  `docker-compose-network-ipv6-parity` Make target.

## Minimal examples

Supported on macOS:

```yaml
networks:
  backend:
    enable_ipv6: true
```

Expected result: `container compose up` creates `backend` and
`container network inspect backend` reports a non-empty `status.ipv6Subnet`.

Correctly rejected until the runtime gains an IPv6-disable primitive:

```yaml
networks:
  backend:
    enable_ipv6: false
```

Expected result: `container compose up` fails before side effects with
`network 'backend' uses unsupported fields enable_ipv6`.

## Documentation checklist

- [x] I checked `STATUS.md`.
- [x] I checked the relevant Docker Compose reference.
- [x] The documented remaining gap is limited to macOS-implementable behavior.
