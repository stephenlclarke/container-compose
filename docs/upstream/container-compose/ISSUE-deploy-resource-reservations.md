# Accept Deploy CPU and memory reservations as local metadata

## Compose surface

`services.<name>.deploy.resources.reservations.cpus`

`services.<name>.deploy.resources.reservations.memory`

## Docker Compose v2 behavior

Docker Compose V2 accepts CPU and memory reservations in local mode. It preserves the reservation metadata in `docker-compose config --format json`, and local dry-run `docker-compose up --no-start SERVICE` proceeds through the ordinary pull, network, and container create plan.

Upstream context checked before this slice:

- No Docker Compose, Compose Spec, compose-go, Moby, or BuildKit issue/PR/discussion directly argued for rejecting CPU or memory Deploy reservations in local Compose mode.
- Local Docker Compose 5.2.0 preserved `deploy.resources.reservations.cpus` and `deploy.resources.reservations.memory` in config output and accepted the service in dry-run local orchestration.

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

This does not require a new Apple runtime primitive for the local Compose path because Docker Compose local mode treats these fields as scheduler metadata rather than hard runtime limits. Deploy reservation pids, devices, and generic resources remain separate gaps because they may imply scheduler or device-resource behavior that is not covered by this local metadata slice.

## Expected behavior

- `container compose config --format json` no longer reports `resources.reservations.cpus` or `resources.reservations.memory` in `unsupportedDeployFields`.
- `container compose up --no-start api` accepts the service and plans ordinary local container creation.
- `deploy.resources.reservations.pids`, `deploy.resources.reservations.devices`, and `deploy.resources.reservations.generic_resources` remain rejected until there is a Docker-compatible local runtime or scheduler mapping.
