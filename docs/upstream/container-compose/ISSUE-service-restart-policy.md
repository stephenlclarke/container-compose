# Compose compatibility gap: service restart policy

## Compose Surface

Service-level `restart` in Compose files:

```yaml
services:
  api:
    image: example/api
    restart: unless-stopped
```

Supported policy values for this slice are `no`, `always`, `unless-stopped`, `on-failure`, and `on-failure:<max-retries>`.

## Docker Compose v2 Behavior

Docker Compose v2 accepts service-level `restart` as a local container restart policy and passes it to the underlying runtime when service containers are created. The policy applies to long-lived service containers created by `up` / `create`, while one-off `docker compose run --rm` containers do not inherit the service policy because one-off lifecycle and removal behavior are different from steady-state service reconciliation.

Reference surfaces:

- Compose services reference: [services.restart](https://docs.docker.com/reference/compose-file/services/#restart)
- Docker container create restart policy reference: [container create --restart](https://docs.docker.com/reference/cli/docker/container/create/#restart)

## Current container-compose Behavior

Before this change, `container-compose` rejected every non-empty service `restart` value as an `apple/container` runtime gap before creating resources.

With the fork-backed runtime restart slices present, `container-compose` can now validate service `restart` and map supported values to `container run --restart <policy>` for service containers.

## Likely Owner

Both:

- `apple/container` needs accepted restart-policy create options and runtime restart scheduling before released upstream branches can rely on the behavior.
- `container-compose` needs to validate and map service-level `restart` to the runtime once that primitive exists.

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

## References

- apple/container issue: [apple/container#286](https://github.com/apple/container/issues/286)
- Existing restart-policy PR reference: [apple/container#1258](https://github.com/apple/container/pull/1258)
- Fork handoff: `ISSUE-restart-policy-create-options.md` and `PR-restart-policy-create-options.md` in `stephenlclarke/container`
- Fork handoff: `ISSUE-restart-policy-runtime.md` and `PR-restart-policy-runtime.md` in `stephenlclarke/container`
- Follow-up gap: `deploy.restart_policy` still needs a normalized model slice before the Swift orchestrator can map it.

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `COMPATIBILITY.md`.
- [x] I checked `PLAN.md`.
