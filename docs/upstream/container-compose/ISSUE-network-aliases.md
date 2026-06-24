# Compose compatibility gap: service network aliases

## Compose surface

`services.<name>.networks.<network>.aliases`

## Docker Compose v2 behavior

Docker Compose lets a service declare alternative hostnames scoped to a specific network. Other containers on the same network can connect using the service name or one of those aliases.

```yaml
services:
  api:
    image: alpine
    networks:
      backend:
        aliases:
          - api.internal

networks:
  backend: {}
```

Docker documents the lower-level primitive as a network-scoped alias on container network connection.

References:

- Compose service network `aliases`: <https://docs.docker.com/reference/compose-file/services/#aliases>
- Docker `network connect --alias`: <https://docs.docker.com/reference/cli/docker/network/connect/>
- Docker networking overview: <https://docs.docker.com/engine/network/>

## Current container-compose behavior

Before this change, `container-compose` rejected any service network aliases as an `apple/container` runtime gap.

With this change, `container-compose` supports aliases for the current single-network local subset by mapping compose-go normalized aliases to the plugin-owned network-alias projection. The current live execution path still renders `container run/create --network <name>,alias=<alias>` through the command-vector bridge while typed service creation is being wired. Invalid aliases and aliases declared on unattached networks are rejected before resources are created.

## Likely owner

both

`apple/container` owns the runtime network attachment alias primitive. `container-compose` owns Compose model validation, single-network subset selection, and projection.

## Minimal example

```yaml
name: alias-demo

services:
  api:
    image: alpine
    command: ["sleep", "infinity"]
    networks:
      backend:
        aliases:
          - api.internal

networks:
  backend: {}
```

Expected runtime behavior on the fork-backed integration branch:

- `container-compose` currently emits `--network alias-demo_backend,alias=api.internal` through the command-vector bridge.
- Peers on the same `apple/container` network can resolve `api.internal` to the service container's attachment address.
- Multi-network alias behavior remains blocked until `apple/container` exposes multi-network attach/connect and source-network-aware DNS behavior.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `DOCKER-COMPOSE-PARITY.md`.
- [x] I checked `PLAN.md`.
