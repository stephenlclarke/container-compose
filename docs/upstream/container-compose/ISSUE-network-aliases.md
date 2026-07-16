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
- Apple container-to-container DNS request: <https://github.com/apple/container/issues/1809>
- Apple DNS forwarding groundwork: <https://github.com/apple/container/pull/1813>
- Apple network-attachment aliases: <https://github.com/apple/container/pull/1815>

## Current container-compose behavior

`container-compose` validates alias syntax and attachment ownership, then rejects every valid network-alias request before resource creation. The runtime can register aliases on repeated `--network` attachment arguments, and plain multi-network attachments are supported at container creation on macOS 26+. However, it configures service containers with only the first attachment gateway as their nameserver and has no container-facing DNS listener to resolve the registry entries. Passing the arguments through would therefore advertise a feature that peers cannot use.

## Likely owner

both

`apple/container` owns the missing container-facing DNS listener and source-network routing model. `container-compose` owns Compose model validation and the early, explicit unsupported error.

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

Current behavior with the fork-backed runtime:

- `container-compose` rejects this project before creating networks, volumes, or containers.
- `apple/container` can register `api.internal` in its per-network registry but cannot answer that lookup from a service container.
- Plain multi-network attachment creation is supported; all alias behavior remains blocked until `apple/container` exposes a container-facing DNS listener with source-network-aware routing.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked relevant upstream DNS design and alias proposals.
