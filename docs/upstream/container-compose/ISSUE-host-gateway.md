# Compose compatibility gap: extra_hosts host-gateway

## Compose surface

`extra_hosts` entries whose address value is `host-gateway`.

## Docker Compose v2 behavior

Docker Compose accepts `host-gateway` in service `extra_hosts` and passes it to Docker's host-entry resolver:

```yaml
services:
  api:
    image: alpine
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

Docker resolves that magic value to the host's internal gateway address when creating the container hosts file.

References:

- Compose service `extra_hosts`: <https://docs.docker.com/reference/compose-file/services/#extra_hosts>
- Docker `container run --add-host` and `host-gateway`: <https://docs.docker.com/reference/cli/docker/container/run/#add-entries-to-container-hosts-file---add-host>

## Current container-compose behavior

Before this change, `container-compose` rejected `host-gateway` before creating resources because released upstream `apple/container` could only accept static IP-literal host entries.

With this change, `container-compose` passes `host-gateway` through to the fork-backed runtime as `--add-host host.docker.internal:host-gateway`. The runtime resolves it to the first network gateway while generating `/etc/hosts`.

## Likely owner

both

`apple/container` owns resolving `host-gateway` to an actual gateway address. `container-compose` owns translating Compose `extra_hosts` syntax into the runtime `--add-host` argument.

## Minimal example

```yaml
name: host-gateway-demo

services:
  api:
    image: alpine
    extra_hosts:
      - "host.docker.internal:host-gateway"
    command: ["cat", "/etc/hosts"]
```

Expected runtime behavior on the fork-backed integration branch:

- `container-compose` emits `--add-host host.docker.internal:host-gateway`.
- The runtime writes a concrete IPv4 gateway address for `host.docker.internal`.
- Containers with no IPv4 gateway fail clearly at runtime instead of receiving an invalid hosts-file literal.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `PLAN.md`.
