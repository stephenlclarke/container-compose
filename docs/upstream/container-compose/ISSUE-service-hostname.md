# Compose compatibility gap: service hostname

## Compose surface

`hostname`

## Docker Compose v2 behavior

Docker Compose maps a service-level `hostname` value to the hostname visible inside each created service container:

```yaml
services:
  api:
    image: alpine
    hostname: api-01
```

Compose requires the value to be a valid RFC1123 hostname. Docker exposes the matching runtime primitive through `docker container run --hostname`.

References:

- Compose service `hostname`: <https://docs.docker.com/reference/compose-file/services/#hostname>
- Docker `container run --hostname`: <https://docs.docker.com/reference/cli/docker/container/run/>

## Current container-compose behavior

Before this change, any non-empty service `hostname` was rejected as an `apple/container` runtime gap.

With this change, `container-compose` validates Compose `hostname` values before creating resources and maps valid values to the plugin-owned runtime hostname projection for service containers, `create`, and one-off `run` containers. The current live execution path still renders `container run/create --hostname` through the command-vector bridge while typed service creation is being wired.

## Likely owner

both

`apple/container` owns the typed runtime hostname primitive. `container-compose` owns the Compose model validation and translation to the runtime projection.

## Minimal example

```yaml
name: hostname-demo

services:
  api:
    image: alpine
    hostname: api-01
    command: ["hostname"]
```

Expected runtime behavior on the fork-backed integration branch:

- `container-compose` currently emits `--hostname api-01` through the command-vector bridge.
- The runtime makes `api-01` visible inside the container.
- `domainname` remains unsupported until `apple/container` and the lower runtime expose a domain-name primitive.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `COMPATIBILITY.md`.
- [x] I checked `PLAN.md`.
