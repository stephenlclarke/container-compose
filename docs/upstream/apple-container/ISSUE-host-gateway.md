# Feature request: resolve host-gateway host entries

## Feature or enhancement request details

Docker accepts a special `host-gateway` value in `--add-host` entries and resolves it to the internal host gateway address for the container network:

```sh
docker container run --add-host host.docker.internal=host-gateway curlimages/curl host.docker.internal:8000
```

Docker Compose uses the same value through service `extra_hosts`:

```yaml
services:
  api:
    image: alpine
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

`apple/container` already has static host-entry support in the local fork and network attachments already carry `ipv4Gateway`. Without a typed runtime-resolved host-entry marker, `container-compose` must reject a common local-development Compose pattern even though the runtime has the gateway information at container start time.

Direction note: after JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), Compose should own `extra_hosts` parsing and the Docker-shaped `host-gateway` string. The Apple-facing primitive is resolving an explicit host-entry marker to the container's network gateway while generating `/etc/hosts`.

Relevant references:

- Docker `container run --add-host` and `host-gateway`: <https://docs.docker.com/reference/cli/docker/container/run/#add-entries-to-container-hosts-file---add-host>
- Compose service `extra_hosts`: <https://docs.docker.com/reference/compose-file/services/#extra_hosts>
- Related upstream host-entry directions: [apple/container#1563](https://github.com/apple/container/pull/1563), [apple/container#1340](https://github.com/apple/container/pull/1340)

## Proposed behavior

- Store a runtime-resolved host-gateway marker in `ContainerConfiguration.HostEntry`.
- Resolve it to the first network interface IPv4 gateway when generating `/etc/hosts`.
- Fail clearly if a caller requests `host-gateway` for a container without an IPv4 gateway.
- Keep configurable daemon-level host-gateway overrides out of this slice.

## Minimal example

Expected behavior:

- The created container receives a `/etc/hosts` entry mapping `host.docker.internal` to the first network gateway address.
- Containers without a network fail before writing an invalid `host-gateway` literal into `/etc/hosts`.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
