# Accept Deploy endpoint-mode as local Compose metadata

## Compose surface

`services.<name>.deploy.endpoint_mode`

## Docker Compose v2 behavior

Docker Compose V2 accepts `deploy.endpoint_mode` in local mode. It preserves the Swarm metadata in `docker-compose config --format json`, and local dry-run `docker-compose up --no-start SERVICE` proceeds through the ordinary pull, network, and container create plan.

Upstream references:

- No Docker Compose, Compose Spec, or compose-go issue/PR directly argued for rejecting `deploy.endpoint_mode` in local Compose mode.
- Moby search results for `endpoint_mode` are Swarm DNS/VIP behavior reports, not local Docker Compose blockers.
- The Docker Compose v2 reference preserves `endpoint_mode: dnsrr` in config output and accepts the service in dry-run local orchestration.

## Current container-compose behavior

Before this slice, the Go normalizer recorded any non-empty `deploy.endpoint_mode` value in `unsupportedDeployFields`, and Swift orchestration rejected the service before `up` or `run` could create resources.

Minimal rejected example:

```yaml
services:
  api:
    image: alpine:3.20
    deploy:
      endpoint_mode: dnsrr
```

## Likely owner

container-compose design gap.

This does not require a new Apple runtime primitive for the local Compose path because Docker Compose local mode accepts the Swarm endpoint-mode metadata without changing ordinary container creation.

## Expected behavior

- `container compose config --format json` no longer reports `unsupportedDeployFields: ["endpoint_mode"]`.
- `container compose up --no-start api` accepts the service and plans ordinary local container creation.
- Swarm VIP/DNSRR endpoint behavior is not claimed for local Apple runtime orchestration.
