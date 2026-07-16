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

This is now verified against the active upstream work, rather than an assumed
missing API:

- [apple/container#1815](https://github.com/apple/container/pull/1815) adds
  the correct narrow alias-registration primitive, but explicitly does not
  make aliases resolvable from containers.
- [apple/container#1813](https://github.com/apple/container/pull/1813) adds
  forwarding and request-context groundwork, but intentionally does not start
  a listener. A wildcard UDP/53 listener races with `mDNSResponder`; binding a
  listener to the vmnet gateway failed with `EADDRNOTAVAIL`, both with the
  vmnet DNS proxy enabled and disabled.

The Compose-side rejection is therefore deliberate and must remain until the
runtime can prove an end-to-end peer lookup. It also keeps `compose run
--use-aliases` correctly marked partial rather than exposing a no-op flag.

## Likely owner

both

`apple/container` owns the missing container-facing DNS listener and
source-network routing model. `container-compose` owns Compose model
validation and the early, explicit unsupported error.

The smallest useful Apple-facing primitive is **not** another Compose parser
or an alias-only API. It is a supported way for the vmnet-backed runtime to
receive DNS requests from a service container, identify the originating
network, and answer them from that network's attachment registry. Whether
that is a vmnet-provided host-bindable endpoint, DNS interception, or a
platform-supported mDNSResponder integration is an Apple runtime decision.

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

## Acceptance evidence for a future Compose slice

Do not enable alias rendering based only on API shape or unit tests. The
runtime handoff must demonstrate all of the following with a real vmnet-backed
network:

1. A peer container resolves an attachment hostname and an alias over the
   network DNS path.
2. The lookup is scoped to the peer's source network, including a container
   with more than one attachment.
3. The resolver's startup does not bind wildcard port 53 or interfere with
   `mDNSResponder`.
4. Alias teardown removes the answer after a container is removed.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked relevant upstream DNS design and alias proposals.
