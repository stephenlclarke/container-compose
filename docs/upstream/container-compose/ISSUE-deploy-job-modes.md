# Compose compatibility gap: local deploy job modes

## Compose surface

`services.<name>.deploy.mode: replicated-job` and `services.<name>.deploy.mode: global-job`

## Docker Compose v2 behavior

Docker Compose accepts Compose Deploy job modes for completion-oriented services. The Compose Deploy Specification describes `replicated-job` and `global-job` as tasks that are expected to complete and exit with code `0`, and it keeps completed tasks until they are explicitly removed.

```yaml
services:
  migrate:
    image: alpine
    command: ["sh", "-c", "echo migrate"]
    deploy:
      mode: replicated-job
      replicas: 2
```

References:

- Compose Deploy `mode`: <https://docs.docker.com/reference/compose-file/deploy/#mode>
- Docker service job behavior: <https://docs.docker.com/reference/cli/docker/service/create/#running-as-a-job>
- Related stopped-container exit metadata: [apple/container#1562](https://github.com/apple/container/pull/1562)

## Current container-compose behavior

Before this change, `container-compose` preserved deploy replica counts as local `scale`, but marked `replicated-job` and `global-job` as unsupported deploy fields. That blocked Compose files that use local completion jobs for database migrations, seed data, or setup steps even though the fork-backed lifecycle adapter can wait for running containers and replay stored exit metadata for stopped containers.

With this change, `container-compose` supports the local Docker Compose job subset with the current fork-backed runtime:

- compose-go normalized deploy mode is preserved as `deployMode`.
- `replicated-job` and `global-job` are no longer reported as unsupported deploy fields.
- `up` starts job replicas detached.
- `up` waits every selected job replica to exit successfully before continuing to later services.
- A non-zero job exit fails `up` before later services start.
- Restart-capable service-level and deploy-level restart policies are rejected for job services before resources are created until `apple/container` exposes a restart-aware wait primitive. Explicit no-restart policies (`restart: no` or `deploy.restart_policy.condition: none`) remain allowed as no restart. The current wait primitive observes one exit and cannot yet report the final job result after runtime restart attempts.

## Likely owner

container-compose owns the local job orchestration.

Released upstream `apple/container` still needs accepted stopped-container exit metadata before this can work without the fork. The fork currently supplies that through the local adaptation of [apple/container#1562](https://github.com/apple/container/pull/1562).

## Minimal example

```yaml
name: job-demo

services:
  migrate:
    image: alpine
    command: ["sh", "-c", "echo migrate"]
    deploy:
      mode: replicated-job
      replicas: 2

  api:
    image: nginx:alpine
    depends_on:
      migrate:
        condition: service_completed_successfully
```

Expected runtime behavior with the current fork-backed runtime:

- `container-compose` creates and starts `job-demo-migrate-1` and `job-demo-migrate-2` detached.
- `container-compose` waits both job containers.
- `api` starts only after both job replicas exit with status `0`.
- If any job replica exits non-zero, `up` fails and `api` is not started.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
