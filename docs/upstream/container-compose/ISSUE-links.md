# Compose compatibility gap: legacy service links

## Compose surface

`services.<name>.links`

## Docker Compose v2 behavior

Docker Compose accepts legacy `links` entries in either `SERVICE` or
`SERVICE:ALIAS` form. Linked services are reachable by the alias, or by the
service name when no alias is provided. Links also express an implicit
dependency between services, similar to `depends_on`.

```yaml
services:
  api:
    image: alpine
    links:
      - redis:cache
    networks:
      - backend

  redis:
    image: redis:7
    networks:
      - backend

networks:
  backend: {}
```

References:

- Compose service `links`: <https://docs.docker.com/reference/compose-file/services/#links>
- Compose service network `aliases`: <https://docs.docker.com/reference/compose-file/services/#aliases>
- Docker `network connect --alias`: <https://docs.docker.com/reference/cli/docker/network/connect/>

## Current container-compose behavior

`container-compose` supports a safe static-host subset:

- The linked service is started before the service declaring the link.
- `SERVICE:ALIAS` maps `ALIAS` to the linked service's resolved IPv4 address
  through a generated source-container `--add-host` entry.
- `SERVICE` maps the linked service name through the same static-host entry.
- The source and target services must share exactly one normalized Compose
  network, including the implicit `default` network.
- The address is resolved during Compose reconciliation. Re-run `compose up`
  after an out-of-band network or address change to recreate dependent source
  containers with the current address.
- A source `extra_hosts` entry using the same hostname as a link alias is
  rejected before side effects rather than relying on host-file ordering.
- Two linked services cannot use the same alias; that ambiguous static-host
  mapping is rejected before side effects.

This intentionally does not claim runtime DNS compatibility. Direct
`services.<name>.networks.<network>.aliases` remains rejected, and
source-scoped dynamic alias resolution, links with zero or multiple shared
networks, and richer external-service discovery need runtime work.

## Likely owner

container-compose

`container-compose` owns legacy Compose link interpretation, dependency
ordering, and static host-entry projection. `apple/container` needs no new
primitive for this limited fallback: the existing `--add-host` surface writes
the source container's static host entries. Full Docker parity still needs
upstream runtime DNS work for source-scoped dynamic aliases.

## Minimal example

```yaml
name: links-demo

services:
  api:
    image: alpine
    command: ["sleep", "infinity"]
    links:
      - redis:cache
    networks:
      - backend

  redis:
    image: redis:7
    networks:
      - backend

networks:
  backend: {}
```

Expected runtime behavior with the current fork-backed runtime:

- `container-compose` creates or reuses `redis` before `api`.
- `container-compose` resolves `redis` on `links-demo_backend` and gives `api`
  `--add-host cache:<redis-ip>` while attaching `api` to that network.
- `external_links` uses the same direct-runtime-inspection and generated-host
  approach for its supported single-network subset.
- The fallback is static per source container, not a runtime DNS record.
  Runtime aliases, dynamic address updates, links with zero or multiple shared
  networks, and source-scoped DNS remain runtime gaps.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
