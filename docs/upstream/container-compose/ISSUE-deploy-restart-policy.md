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

This slice supports the non-job service subset that can be represented by the current fork-backed `apple/container` restart runtime: `condition: none`, `condition: any` or an empty policy, `condition: on-failure` with optional `max_attempts`, and deploy restart timing fields `delay` and `window`. Restart-capable deploy job policies are rejected until the runtime can expose a restart-aware job wait primitive; explicit `condition: none` remains allowed as no restart.

## Docker Compose v2 Behavior

Docker Compose v2 documents `deploy.restart_policy` with `condition`, `delay`, `max_attempts`, and `window`. When `deploy.restart_policy` is set, Docker Compose considers it before the service-level `restart` key. If deploy policy is absent, Compose falls back to `restart`.

Reference surfaces:

- Compose Deploy reference: [deploy.restart_policy](https://docs.docker.com/reference/compose-file/deploy/#restart_policy)
- Compose services reference: [services.restart](https://docs.docker.com/reference/compose-file/services/#restart)

## Current container-compose Behavior

Before this change, the compose-go normalizer collapsed every configured `deploy.restart_policy` into `unsupportedDeployFields`, so Swift orchestration could only reject the whole field and could not distinguish supported policy mode/retry data from unsupported timing data.

With the fork-backed runtime restart slices present, `container-compose` can now normalize the structured policy and map the Docker-compatible subset to the plugin-owned restart-policy projection for non-job service containers. The current live execution path still renders `container run --restart <policy>` through the command-vector bridge while typed service creation is being wired. For `deploy.mode: replicated-job` and `deploy.mode: global-job`, restart-capable policies reject before resource creation because the current wait primitive observes one container exit and cannot yet wait through runtime restart attempts to the final job result.

## Likely Owner

Both:

- `container-compose` owns Compose model normalization, deploy-over-service precedence, one-off `run` behavior, and early validation for unsupported deploy restart fields.
- `apple/container` needs accepted restart-policy create/runtime/timing primitives before upstream-compatible builds can rely on the behavior.

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

This is the current command-vector bridge output. The deploy restart policy wins over `restart: unless-stopped`, matching Docker Compose precedence.

## Runtime Timing Example

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

Expected result on the fork-backed integration branch: `container-compose`
passes `delay` and `window` through to the fork's restart-policy timing
primitive for service containers. Released upstream support is pending an
equivalent `apple/container` timing API.

## Deploy Job Caveat

Docker Compose can combine job modes with restart policies, but `container-compose` needs an `apple/container` wait primitive that reports the final job result after any runtime restart attempts. Until that primitive exists, deploy job services reject restart-capable service-level and deploy-level restart policies before containers are created. Explicit no-restart policies remain allowed.

## References

- apple/container issue: [apple/container#286](https://github.com/apple/container/issues/286)
- Existing restart-policy PR reference: [apple/container#1258](https://github.com/apple/container/pull/1258)
- Fork handoff: `docs/upstream/apple-container/ISSUE-restart-policy-create-options.md` and `docs/upstream/apple-container/PR-restart-policy-create-options.md` in `stephenlclarke/container-compose`, backed by `stephenlclarke/container` branch `restart-policy-create-options` commit `c5668c19d139b1aeb7e2529cb1dedd01fb4532c1`.
- Fork handoff: `docs/upstream/apple-container/ISSUE-restart-policy-runtime.md` and `docs/upstream/apple-container/PR-restart-policy-runtime.md` in `stephenlclarke/container-compose`, backed by `stephenlclarke/container` branch `restart-policy-runtime` commit `b41bb830db708bc839c94e01c8a75c7fecbe3db0`.
- Fork handoff: `docs/upstream/apple-container/ISSUE-restart-policy-timing.md` and `docs/upstream/apple-container/PR-restart-policy-timing.md` in `stephenlclarke/container-compose`, backed by `stephenlclarke/container` branch `restart-policy-timing` commit `8b1eff72481fa497328414e0483a08c768826f1a`.
- Previous plugin handoff: `docs/upstream/container-compose/ISSUE-service-restart-policy.md` and `docs/upstream/container-compose/PR-service-restart-policy.md`

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
