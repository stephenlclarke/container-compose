# Compose GPU Requests

## Compose surface

`services.<name>.gpus`

`services.<name>.deploy.resources.reservations.devices` with the generic `gpu` capability

## Docker Compose v2 behavior

Docker Compose accepts generic GPU service requests and generic Deploy GPU device reservations in local mode. `docker-compose config --format json` normalizes `gpus: all` as `{"count": -1}` and preserves Deploy GPU reservations under `deploy.resources.reservations.devices`.

```yaml
services:
  trainer:
    image: alpine:3.20
    gpus: all
  worker:
    image: alpine:3.20
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: [gpu]
              count: all
```

References:

- Compose service `gpus`: <https://docs.docker.com/reference/compose-file/services/#gpus>
- Compose Deploy device reservations: <https://docs.docker.com/reference/compose-file/deploy/#devices>
- Docker CLI `--gpus`: <https://docs.docker.com/reference/cli/docker/container/run/#gpus>
- Apple runtime request: [apple/container#1511](https://github.com/apple/container/issues/1511)
- Lower-runtime GPU request: [apple/containerization#480](https://github.com/apple/containerization/issues/480)
- Lower-runtime virtio-gpu PR: [apple/containerization#569](https://github.com/apple/containerization/pull/569)

## Current container-compose behavior

`container-compose` supports the Docker-compatible generic GPU subset available in the matched `stephenlclarke` runtime lane:

- `gpus: all`, `gpus: [{count: 1}]`, `gpus: [{device_ids: ["0"]}]`, and equivalent `driver: virtio` requests map to `container run/create --gpus`.
- Deploy reservations with the generic `gpu` capability map to the same runtime path.
- Unsupported vendor drivers, extra capabilities, driver options, multiple GPUs, non-zero device IDs, and non-GPU Deploy device reservations fail before resource creation.
- The runtime requests the Apple virtio-gpu VM device and projects supported Linux DRM character-device metadata when the running guest kernel exposes `/dev/dri`.

## Likely owner

`container-compose` owns Compose model normalization, Docker-compatible service/deploy validation, dry-run rendering, and Docker Compose parity tests.

`apple/container` owns the `--gpus` parser, runtime-data bridge, and OCI device-node projection. `apple/containerization` owns the VM graphics-device primitive.

## Minimal example

```yaml
services:
  shell:
    image: alpine:3.20
    command: ["true"]
    gpus: all
```

Expected fork-backed behavior:

- `container compose config --format json` preserves the normalized GPU request.
- `container compose --dry-run up shell` emits `--gpus all`.
- `container compose --dry-run create shell` emits `--gpus all`.
- `container compose --dry-run run shell true` emits `--gpus all`.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
