# Accept Deploy CPU and memory reservations as local metadata

## Compose surface

`services.<name>.deploy.resources.reservations.cpus`

`services.<name>.deploy.resources.reservations.memory`

## Docker Compose v2 behavior

Docker Compose V2 accepts CPU and memory reservations in local mode. It preserves the reservation metadata in `docker-compose config --format json`, and local dry-run `docker-compose up --no-start SERVICE` proceeds through the ordinary pull, network, and container create plan.

Upstream references:

- No Docker Compose, Compose Spec, compose-go, Moby, or BuildKit issue/PR/discussion directly argued for rejecting CPU or memory Deploy reservations in local Compose mode.
- The Docker Compose v2 reference preserves `deploy.resources.reservations.cpus` and `deploy.resources.reservations.memory` in config output and accepts the service in dry-run local orchestration.

## Current container-compose behavior

Before this slice, the Go normalizer recorded CPU and memory reservations in `unsupportedDeployFields`, and Swift orchestration rejected the service before `up` or `run` could create resources.

Minimal rejected example:

```yaml
services:
  api:
    image: alpine:3.20
    deploy:
      resources:
        reservations:
          cpus: "0.25"
          memory: 32M
```

## Likely owner

container-compose design gap.

The initial acceptance slice did not require a new Apple runtime primitive.
Its CPU conclusion remains correct: Docker Compose local mode treats Deploy CPU
reservation as scheduler metadata. Deploy memory reservation is a narrower
exception: Docker Compose also maps it to the Engine soft-memory reservation,
and container-compose now maps it through the pre-existing generic runtime
primitive. The follow-up is tracked in
[ISSUE-deploy-memory-reservation-projection.md](ISSUE-deploy-memory-reservation-projection.md).

Deploy reservation pids, non-GPU devices, and generic resources remain
separate gaps because they may imply scheduler or device-resource behavior that
is not covered by this local metadata slice. Generic GPU device reservations
are handled by the service GPU runtime slice.

## Expected behavior

- `container compose config --format json` no longer reports `resources.reservations.cpus` or `resources.reservations.memory` in `unsupportedDeployFields`.
- `container compose up --no-start api` accepts the service. CPU reservation stays metadata, while a non-zero memory reservation renders the existing generic `--memory-reservation` runtime argument.
- `deploy.resources.reservations.pids`, non-GPU `deploy.resources.reservations.devices`, and `deploy.resources.reservations.generic_resources` remain rejected until there is a Docker-compatible local runtime or scheduler mapping.
