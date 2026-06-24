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

Before this change, `container-compose` rejected all `links` entries as an
`apple/container` runtime gap.

With this change, `container-compose` supports the safe local subset that can be
represented by the fork-backed single-network alias primitive:

- The linked service is started before the service declaring the link.
- `SERVICE:ALIAS` maps `ALIAS` to the linked service's network attachment.
- `SERVICE` maps the linked service name as the alias.
- The source and target services must share exactly one explicit Compose
  network.
- Shared aliases are rejected before side effects because the current
  `apple/container` DNS lookup cannot disambiguate Docker's ambiguous shared
  alias behavior yet.

## Likely owner

container-compose

`container-compose` owns legacy Compose link interpretation and dependency
ordering. `apple/container` already owns the current single-network alias
primitive in the fork. The current live execution path projects those aliases
through `--network ...,alias=...` command-vector output while typed service
creation is being wired. Full Docker parity still needs upstream runtime DNS
work for source-scoped link aliases and shared aliases.

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

Expected runtime behavior on the fork-backed integration branch:

- `container-compose` creates or reuses `redis` before `api`.
- The `redis` service container currently receives `--network links-demo_backend,alias=cache` through the command-vector bridge.
- The `api` service container attaches to the same network.
- `external_links`, implicit default-network link aliases, multi-network links,
  and shared aliases remain documented runtime/DNS gaps.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `DOCKER-COMPOSE-PARITY.md`.
- [x] I checked `PLAN.md`.
