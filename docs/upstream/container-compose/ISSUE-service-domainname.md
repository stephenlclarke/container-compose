# Compose compatibility gap: service domainname

## Compose surface

`domainname`

## Docker Compose v2 behavior

Docker Compose maps a service-level `domainname` value to the NIS domain name visible inside each created service container:

```yaml
services:
  api:
    image: alpine
    domainname: example.test
```

Compose requires the value to be a valid hostname-like domain value. Docker exposes the matching runtime primitive through `docker container run --domainname`.

References:

- Compose service `domainname`: <https://docs.docker.com/reference/compose-file/services/#domainname>
- Docker `container run --domainname`: <https://docs.docker.com/reference/cli/docker/container/run/>
- Runtime handoff files: `docs/upstream/apple-container/ISSUE-domainname.md` and `docs/upstream/apple-container/PR-domainname.md`

## Current container-compose behavior

Before this change, any non-empty service `domainname` was rejected as an `apple/container` runtime gap.

With this change, `container-compose` validates Compose `domainname` values before creating resources and maps valid values to the plugin-owned runtime domain-name projection for service containers, `create`, and one-off `run` containers. The current live execution path still renders `container run/create --domainname` through the command-vector bridge while typed service creation is being wired.

## Likely owner

both

`apple/container` owns the typed runtime domain-name primitive. `container-compose` owns the Compose model validation and translation to the runtime projection.

## Minimal example

```yaml
name: domainname-demo

services:
  api:
    image: alpine
    domainname: example.test
    command: ["sh", "-c", "dnsdomainname || true"]
```

Expected runtime behavior on the fork-backed integration branch:

- `container-compose` currently emits `--domainname example.test` through the command-vector bridge.
- The runtime makes `example.test` visible as the container's NIS domain name.
- Released upstream `apple/container` branches still need accepted domain-name support before this can work without the fork.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `COMPATIBILITY.md`.
- [x] I checked `PLAN.md`.
