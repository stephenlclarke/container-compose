# Compose compatibility gap: service devices

## Compose surface

`services.<name>.devices`

## Docker Compose v2 behavior

Docker Compose accepts service device mappings, preserves them in normalized config, and projects them to Docker Engine `HostConfig.Devices`:

```yaml
services:
  api:
    image: alpine:3.20
    devices:
      - "/dev/null:/dev/xnull:rw"
      - "/dev/zero"
```

References:

- Compose service `devices`: <https://docs.docker.com/reference/compose-file/services/#devices>
- Docker run `--device`: <https://docs.docker.com/reference/cli/docker/container/run/#add-host-device-to-container---device>
- Related upstream Apple requests: [apple/container#640](https://github.com/apple/container/issues/640), [apple/container#1680](https://github.com/apple/container/issues/1680), [apple/container#1683](https://github.com/apple/container/issues/1683), [apple/container#1511](https://github.com/apple/container/issues/1511), [apple/containerization#74](https://github.com/apple/containerization/issues/74), [apple/containerization#480](https://github.com/apple/containerization/issues/480), and [apple/containerization#569](https://github.com/apple/containerization/pull/569).

## Current container-compose behavior

Before this change, `devices` was grouped with GPU and credential access fields and rejected before resource creation.

With this change, `container-compose` supports Docker Compose service `devices` for the runtime-supported Linux VM device table:

- compose-go normalized `devices` values remain visible through `compose config --format json`;
- `up`, `create`, and one-off `run` validate device syntax before runtime commands;
- the command-vector bridge renders repeatable `container run/create --device` arguments for the fork-backed runtime;
- invalid relative container paths or invalid permission strings fail before side effects.

Compatibility note: Docker Compose can pass relative target strings through Docker Engine in ambiguous short-form cases such as `/dev/null:rw`. The fork-backed CLI bridge requires absolute targets when a target is provided, so that form is rejected instead of being silently interpreted as Docker CLI permission shorthand.

## Likely owner

`container-compose` owns Compose model validation, Docker-compatible service-device mapping, dry-run rendering, and Docker Compose parity tests.

`apple/container` owns the Docker-compatible `--device` CLI/API bridge and resolves supported Linux VM device paths to known Linux device metadata. `apple/containerization` owns projecting typed OCI `linux.devices` values into generated runtime specs. USB, SD-card, PCI, GPU, arbitrary guest-side device discovery, and arbitrary macOS hardware passthrough remain separate lower-runtime/virtualization gaps.

## Minimal example

```yaml
services:
  api:
    image: alpine:3.20
    command: ["true"]
    devices:
      - "/dev/null:/dev/xnull:rw"
      - "/dev/zero"
```

Expected fork-backed behavior:

- `container compose config --format json` preserves both device mappings.
- `container compose --dry-run up api` emits `--device /dev/null:/dev/xnull:rw` and `--device /dev/zero`.
- `container compose --dry-run create api` emits the same device mappings.
- `container compose --dry-run run api true` emits the same device mappings.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `PLAN.md`.
