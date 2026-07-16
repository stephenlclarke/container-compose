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

With this change, `container-compose` supports aliases for the current single-network local subset by mapping compose-go normalized aliases to the plugin-owned network-alias projection. The current live execution path emits repeatable `container run/create --network <name>` arguments, so plain multi-network attachments are supported at container creation on macOS 26+. Aliases remain intentionally limited to one attachment: the runtime's container DNS configuration uses the primary attachment and does not yet provide Docker-compatible source-network-aware DNS. Invalid aliases and aliases declared on unattached networks are rejected before resources are created.

## Likely owner

both

`apple/container` owns the runtime network attachment alias primitive and multi-attachment creation. `container-compose` owns Compose model validation, the alias subset selection, and projection.

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

Expected runtime behavior with the current fork-backed runtime:

- `container-compose` emits `--network alias-demo_backend,alias=api.internal` through the command-vector bridge.
- Peers on the same `apple/container` network can resolve `api.internal` to the service container's attachment address.
- Plain multi-network attachment creation is supported; multi-network alias behavior remains blocked until `apple/container` exposes source-network-aware DNS behavior.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
