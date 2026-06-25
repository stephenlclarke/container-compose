# Compose compatibility gap: runtime config and secret materialization

## Compose Surface

Top-level Compose `configs` and `secrets` can define file-like data that services mount into containers:

```yaml
services:
  api:
    image: example/api
    configs:
      - source: app_config
        target: /etc/app.conf
    secrets:
      - source: app_token
        target: api-token

configs:
  app_config:
    content: |
      enabled=true

secrets:
  app_token:
    environment: APP_TOKEN
```

## Docker Compose v2 Behavior

Docker Compose mounts granted configs and secrets as files. Config source data can come from `file`, `environment`, `content`, or `external`. Secret source data can come from `file` or `environment` for Docker Compose local workflows.

Reference surfaces:

- Compose configs reference: [configs](https://docs.docker.com/reference/compose-file/configs/)
- Compose secrets reference: [secrets](https://docs.docker.com/reference/compose-file/secrets/)

## Current container-compose Behavior

Before this change, `container-compose` supported only file-backed runtime service `configs` and `secrets`. It rejected `configs.content`, `configs.environment`, and `secrets.environment` before creating resources even though those sources can be represented as local files and mounted through existing `apple/container` bind-mount primitives.

With this change, `container-compose` materializes Docker Compose local file-like sources into deterministic project-scoped files under the per-user state root, mounts them read-only, and removes them during `down` after project containers are removed.

## Likely Owner

`container-compose` owns this local-development behavior because the runtime already supports read-only file bind mounts. `apple/container` should still own any future first-class external config/secret store, lookup, or ownership-remapping primitive.

## Minimal Example

```yaml
name: materialized-config-secret-demo

services:
  api:
    image: alpine
    configs:
      - source: inline_config
        target: /etc/inline.conf
    secrets:
      - source: env_secret
        target: api-token

configs:
  inline_config:
    content: |
      inline=true

secrets:
  env_secret:
    environment: API_TOKEN
```

Expected runtime behavior:

```text
container run --volume <state>/configs/inline_config-<hash>:/etc/inline.conf:ro --volume <state>/secrets/env_secret-<hash>:/run/secrets/api-token:ro ...
```

## References

- Docker Compose configs: [configs](https://docs.docker.com/reference/compose-file/configs/)
- Docker Compose secrets: [secrets](https://docs.docker.com/reference/compose-file/secrets/)
- Related compatibility docs: `STATUS.md`
- Related plan docs: `PLAN.md`

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `PLAN.md`.
