# Compose compatibility gap: service sysctls

## Compose surface

`services.<name>.sysctls`

## Docker Compose v2 behavior

Docker Compose accepts service-level namespaced kernel parameters as either mapping values or list values that normalize to name/value pairs.

```yaml
services:
  api:
    image: alpine:3.20
    sysctls:
      net.core.somaxconn: "1024"
      net.ipv4.ip_forward: "1"
```

References:

- Compose service `sysctls`: <https://docs.docker.com/reference/compose-file/services/#sysctls>
- Docker run `--sysctl`: <https://docs.docker.com/reference/cli/docker/container/run/#sysctl>
- Runtime handoff in the local container fork: `ISSUE-sysctl-cli.md` / `PR-sysctl-cli.md`

## Current container-compose behavior

Before this change, `container-compose` preserved compose-go normalized `sysctls` in the Swift model but rejected every service that declared them as an `apple/container` runtime gap.

With this change, `container-compose` supports the plugin-owned mapping:

- compose-go normalized `sysctls` are rendered deterministically.
- `up`, `create`, and one-off `run` render repeatable `container run/create --sysctl name=value` arguments.
- Empty sysctl names and names containing `=` are rejected before runtime commands.

## Likely owner

`container-compose` owns the Compose model validation and command rendering.

`apple/container` owns the runtime `--sysctl` surface and Linux namespace support. The local fork already has `ContainerConfiguration.sysctls`; the new container handoff exposes it through repeatable `container run/create --sysctl name=value`.

## Minimal example

```yaml
name: sysctl-demo

services:
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 3600"]
    sysctls:
      net.core.somaxconn: "1024"
```

Expected integration-branch behavior:

- `container-compose` renders `--sysctl net.core.somaxconn=1024`.
- `apple/container` stores the value in `ContainerConfiguration.sysctls`.
- The Linux runtime applies supported namespaced sysctls when generating the runtime configuration.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `COMPATIBILITY.md`.
- [x] I checked `STATUS.md`.
