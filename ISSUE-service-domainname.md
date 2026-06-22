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
- Runtime handoff files in the container fork: `ISSUE-domainname.md` and `PR-domainname.md`

## Current container-compose behavior

Before this change, any non-empty service `domainname` was rejected as an `apple/container` runtime gap.

With this change, `container-compose` validates Compose `domainname` values before creating resources and maps valid values to the fork-backed `container run/create --domainname` runtime surface for service containers, `create`, and one-off `run` containers.

## Likely owner

both

`apple/container` owns the runtime domain-name primitive. `container-compose` owns the Compose model validation and translation to the runtime argument.

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

- `container-compose` emits `--domainname example.test`.
- The runtime makes `example.test` visible as the container's NIS domain name.
- Released upstream `apple/container` branches still need accepted domain-name support before this can work without the fork.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `COMPATIBILITY.md`.
- [x] I checked `PLAN.md`.
