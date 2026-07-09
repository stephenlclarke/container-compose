# Compose compatibility gap: network IPAM options

## Compose surface

- `networks.<name>.ipam.options`

## Docker Compose v2 behavior

The Compose specification allows driver-specific IPAM options under a project network. Docker Compose currently tracks a bug where these values are parsed but not passed to Docker Engine network creation.

```yaml
services:
  api:
    image: alpine:3.20
    networks:
      - backend
networks:
  backend:
    ipam:
      options:
        com.example.ipam: enabled
```

References:

- Docker Compose issue: <https://github.com/docker/compose/issues/13785>
- Compose-go approved model fix: <https://github.com/compose-spec/compose-go/pull/870>
- Compose network IPAM reference: <https://docs.docker.com/reference/compose-file/networks/#ipam>

## Current container-compose behavior

Before this change, the pinned `compose-go` dependency exposed `IPAMConfig.Options`, but the normalizer did not mark those values as mapped or unsupported. A Compose project using `networks.<name>.ipam.options` could therefore reach orchestration with the driver-specific options silently ignored.

With this change, `container-compose` records `ipam.options` in the normalized network `unsupportedFields` list and rejects the project before creating networks or service containers.

## Likely owner

`container-compose` owns the no-side-effects rejection while Apple network creation lacks an IPAM option primitive. A future Apple runtime change would be needed to map these values instead of rejecting them.

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
    ipam:
      options:
        com.example.ipam: enabled
```

Expected fork-backed behavior:

- `container compose config --format json` preserves that the network uses unsupported `ipam.options` metadata in the normalized model.
- `container compose up api` fails before resource creation with an unsupported-network message.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked the relevant upstream Compose docs.
