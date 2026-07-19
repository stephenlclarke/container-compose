# Compose compatibility gap: project network options

## Compose surface

- `networks.<name>.driver`
- `networks.<name>.attachable`
- `networks.<name>.enable_ipv4: false`
- `networks.<name>.enable_ipv6: false`
- `networks.<name>.ipam.options`

## Docker Compose v2 behavior

The Compose specification exposes project network driver selection, standalone
attachment, IP-family controls, and driver-specific IPAM options. Docker
Compose preserves these fields in `config`; docker/compose#13785 separately
tracks its current failure to pass `ipam.options` into Docker Engine network
creation.

```yaml
services:
  api:
    image: alpine:3.20
    networks:
      - backend
networks:
  backend:
    driver: overlay
    attachable: true
    enable_ipv4: false
    enable_ipv6: false
    ipam:
      options:
        com.example.ipam: enabled
```

References:

- Docker Compose issue: <https://github.com/docker/compose/issues/13785>
- Approved compose-go model PR: <https://github.com/compose-spec/compose-go/pull/870>
- Compose network reference: <https://docs.docker.com/reference/compose-file/networks/>
- Compose network IPAM reference: <https://docs.docker.com/reference/compose-file/networks/#ipam>

## Current container-compose behavior

The pinned `compose-go` dependency exposes all five fields. The normalizer maps
the default bridge driver, ordinary IPv4 behavior, an explicit IPv6 subnet, and
`enable_ipv6: true` with or without a subnet. vmnet assigns an IPv6 prefix when
the generic network-create path has no explicit IPv6 subnet. It records custom
drivers, `attachable: true`, `enable_ipv4: false`, `enable_ipv6: false`, and
`ipam.options` in the normalized network `unsupportedFields` list.

Runtime-backed commands reject those markers before creating networks or
service containers instead of silently ignoring them.

## Likely owner

`container-compose` owns the no-side-effects rejection. Future Apple runtime
changes would be needed to select custom drivers, disable IPv4 or IPv6, or pass
IPAM options instead of rejecting them. Automatic IPv6 allocation is already a
generic vmnet behavior; [the dedicated IPv6 handoff](ISSUE-network-ipv6-auto.md)
records the Compose mapping and the remaining disablement gap.

## Minimal example

```yaml
services:
  api:
    image: alpine:3.20
    command: ["true"]
    networks:
      - backend
networks:
  backend:
    driver: overlay
    attachable: true
    enable_ipv4: false
    enable_ipv6: false
    ipam:
      options:
        com.example.ipam: enabled
```

Expected fork-backed behavior:

- `container compose config --format json` preserves every unsupported project
  network marker in the normalized model.
- `container compose up api` fails before resource creation with an unsupported-network message.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked the relevant upstream Compose docs.
