# Compose compatibility gap: default-network links coverage

## Compose surface

`links` with services that do not explicitly declare `networks`

## Docker Compose v2 behavior

Docker Compose creates a project-scoped `default` network when services do not opt out of networking or declare another network. Legacy `links` between those services use that default network and also imply startup ordering:

```yaml
services:
  api:
    image: alpine
    links:
      - redis:cache

  redis:
    image: redis:7
```

After compose-go normalization, both services are attached to `default` and the project contains a `default` network with the runtime name `<project>_default`.

References:

- Compose service `links`: <https://docs.docker.com/reference/compose-file/services/#links>
- Compose default network behavior: <https://docs.docker.com/reference/compose-file/networks/#the-default-network>
- compose-go normalized project model: <https://github.com/compose-spec/compose-go>

## Current container-compose behavior

The runtime mapping already supports links when source and target services share exactly one normalized Compose network. That includes the compose-go normalized implicit `default` network.

## Likely owner

container-compose

`container-compose` owns the Compose model translation and documentation. No new `apple/container` primitive is needed for the normalized single-network case beyond the existing fork-backed alias surface. The current live execution path still renders aliases through the command-vector bridge while typed service creation is being wired.

## Minimal example

```yaml
name: default-links-demo

services:
  api:
    image: alpine
    links:
      - redis:cache

  redis:
    image: redis:7
```

Expected runtime behavior with the current fork-backed runtime:

- compose-go normalizes both services onto `default`.
- `container-compose` creates `default-links-demo_default`.
- `container-compose` starts `redis` before `api` and currently emits `--network default-links-demo_default,alias=cache` for the linked target service through the command-vector bridge.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
