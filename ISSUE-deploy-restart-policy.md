# Compose compatibility gap: deploy restart policy

## Compose Surface

Compose Deploy `restart_policy` in service definitions:

```yaml
services:
  worker:
    image: example/worker
    deploy:
      restart_policy:
        condition: on-failure
        max_attempts: 3
```

This slice supports the subset that can be represented by the current fork-backed `apple/container` restart runtime: `condition: none`, `condition: any` or an empty policy, and `condition: on-failure` with optional `max_attempts`.

## Docker Compose v2 Behavior

Docker Compose v2 documents `deploy.restart_policy` with `condition`, `delay`, `max_attempts`, and `window`. When `deploy.restart_policy` is set, Docker Compose considers it before the service-level `restart` key. If deploy policy is absent, Compose falls back to `restart`.

Reference surfaces:

- Compose Deploy reference: [deploy.restart_policy](https://docs.docker.com/reference/compose-file/deploy/#restart_policy)
- Compose services reference: [services.restart](https://docs.docker.com/reference/compose-file/services/#restart)

## Current container-compose Behavior

Before this change, the compose-go normalizer collapsed every configured `deploy.restart_policy` into `unsupportedDeployFields`, so Swift orchestration could only reject the whole field and could not distinguish supported policy mode/retry data from unsupported timing data.

With the fork-backed runtime restart slices present, `container-compose` can now normalize the structured policy and map the Docker-compatible subset to `container run --restart <policy>` for service containers.

## Likely Owner

Both:

- `container-compose` owns Compose model normalization, deploy-over-service precedence, one-off `run` behavior, and early validation for unsupported deploy restart fields.
- `apple/container` needs accepted restart-policy create/runtime primitives before released upstream branches can rely on the behavior. It also needs future restart timing primitives before `deploy.restart_policy.delay` and `deploy.restart_policy.window` can be supported instead of rejected.

## Minimal Example

```yaml
name: deploy-restart-policy-demo

services:
  worker:
    image: example/worker
    restart: unless-stopped
    deploy:
      restart_policy:
        condition: on-failure
        max_attempts: 3
```

Expected runtime invocation on the fork-backed integration branch:

```text
container run --restart on-failure:3 ...
```

The deploy restart policy wins over `restart: unless-stopped`, matching Docker Compose precedence.

## Remaining apple/container Gap Example

```yaml
services:
  worker:
    image: example/worker
    deploy:
      restart_policy:
        condition: on-failure
        delay: 5s
        window: 30s
```

Expected result for now: `container-compose` rejects `deploy.restart_policy.delay` and `deploy.restart_policy.window` before creating resources because the current `apple/container` restart policy model does not expose configurable restart delay or success-window semantics.

## References

- apple/container issue: [apple/container#286](https://github.com/apple/container/issues/286)
- Existing restart-policy PR reference: [apple/container#1258](https://github.com/apple/container/pull/1258)
- Fork handoff: `ISSUE-restart-policy-create-options.md` and `PR-restart-policy-create-options.md` in `stephenlclarke/container`
- Fork handoff: `ISSUE-restart-policy-runtime.md` and `PR-restart-policy-runtime.md` in `stephenlclarke/container`
- Previous plugin handoff: `ISSUE-service-restart-policy.md` and `PR-service-restart-policy.md`

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `COMPATIBILITY.md`.
- [x] I checked `PLAN.md`.
