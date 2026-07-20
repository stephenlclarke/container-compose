# Isolate deterministic anonymous volume identities

## Compose surface

`services.<name>.volumes` entries of type `volume` without a `source`, including `compose run` one-off containers.

## Docker Compose v2 behavior

Docker Compose V2 creates a separate anonymous volume for every container mount. Two single-replica services that both mount an anonymous volume at `/scratch` must not share state, and `compose run` must receive its own volume rather than reusing the managed service container's mount.

## Current container-compose behavior

The Compose adapter derived deterministic anonymous volume names solely from the project and mount target unless a service had multiple replicas. Consequently, these independent mounts selected the same Apple runtime volume:

```yaml
services:
  api:
    image: alpine:3.20
    volumes:
      - type: volume
        target: /scratch
  worker:
    image: alpine:3.20
    volumes:
      - type: volume
        target: /scratch
```

The same collision occurred between a one-off `compose run` container and a single managed service container with the same target. It could cause data leakage between otherwise independent Compose containers.

## Likely owner

container-compose design gap.

The Apple runtime already provides named volume creation and mounting. Compose owns the Docker-specific identity policy and can fix it without changing an Apple-facing API. A 2026-07-20 search found no matching Apple Container or compose-go issue; Apple `container` pull requests [#768](https://github.com/apple/container/pull/768) and [#769](https://github.com/apple/container/pull/769) supply the anonymous and implicit named volume primitives, while [#398](https://github.com/apple/container/pull/398) establishes the Compose-plugin ownership boundary.

## Expected behavior

- A managed anonymous volume name is deterministic for its project, service, replica index, and target.
- A one-off anonymous volume name is deterministic for its project, service, generated or requested one-off container name, and target.
- `up --renew-anon-volumes`, selected `down --volumes`, and resource reporting resolve the same managed service identities.
- Docker Compose V2 runtime comparison confirms that same-target managed services and a one-off container receive three distinct anonymous volumes.
