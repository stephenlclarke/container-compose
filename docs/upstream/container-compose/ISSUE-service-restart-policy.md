# Compose compatibility gap: service restart policy

## Compose Surface

Service-level `restart` in Compose files:

```yaml
services:
  api:
    image: example/api
    restart: unless-stopped
```

Supported policy values for non-job services are `no`, `always`, `unless-stopped`, `on-failure`, and `on-failure:<max-retries>`.

## Docker Compose v2 Behavior

Docker Compose v2 accepts service-level `restart` as a local container restart policy and passes it to the underlying runtime when service containers are created. The policy applies to long-lived service containers created by `up` / `create`, while one-off `docker compose run --rm` containers do not inherit the service policy because one-off lifecycle and removal behavior are different from steady-state service reconciliation.

Reference surfaces:

- Compose services reference: [services.restart](https://docs.docker.com/reference/compose-file/services/#restart)
- Docker container create restart policy reference: [container create --restart](https://docs.docker.com/reference/cli/docker/container/create/#restart)

## Current container-compose Behavior

Before this change, `container-compose` rejected every non-empty service `restart` value as an `apple/container` runtime gap before creating resources.

With the fork-backed runtime restart slices present, `container-compose` can now validate service `restart` and map supported values to the plugin-owned restart-policy projection for non-job service containers. The current live execution path still renders `container run --restart <policy>` through the command-vector bridge while typed service creation is being wired. Job-mode services reject restart-capable policies until `apple/container` exposes a restart-aware wait primitive; explicit `restart: no` remains allowed as no restart.

## Likely Owner

Both:

- `apple/container` needs accepted restart-policy create options and runtime restart scheduling before upstream-compatible builds can rely on the behavior.
- `container-compose` needs to validate and map service-level `restart` to typed runtime create options once that primitive exists.

## Minimal Example

```yaml
name: restart-policy-demo

services:
  api:
    image: example/api
    restart: on-failure:3
```

Expected runtime invocation on the fork-backed integration branch:

```text
container run --restart on-failure:3 ...
```

This is the current command-vector bridge output; typed execution should pass `ContainerCreateOptions.restartPolicy` directly.

## References

- apple/container issue: [apple/container#286](https://github.com/apple/container/issues/286)
- Existing restart-policy PR reference: [apple/container#1258](https://github.com/apple/container/pull/1258)
- Fork handoff: `docs/upstream/apple-container/ISSUE-restart-policy-create-options.md` and `docs/upstream/apple-container/PR-restart-policy-create-options.md` in `stephenlclarke/container-compose`, backed by `stephenlclarke/container` branch `restart-policy-create-options` commit `c5668c19d139b1aeb7e2529cb1dedd01fb4532c1`.
- Fork handoff: `docs/upstream/apple-container/ISSUE-restart-policy-runtime.md` and `docs/upstream/apple-container/PR-restart-policy-runtime.md` in `stephenlclarke/container-compose`, backed by `stephenlclarke/container` branch `restart-policy-runtime` commit `b41bb830db708bc839c94e01c8a75c7fecbe3db0`.
- Follow-up gap: restart-capable job policies need an `apple/container` wait primitive that reports the final job result after runtime restart attempts.

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
