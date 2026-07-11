# Compose compatibility gap: block I/O controls

## Compose surface

`services.<name>.blkio_config`

## Docker Compose v2 behavior

Docker Compose accepts block I/O configuration for service containers, including a global weight, per-device weights, and per-device read/write throughput or I/O operation throttles.

```yaml
services:
  db:
    image: postgres:16
    blkio_config:
      weight: 500
      weight_device:
        - path: "8:0"
          weight: 700
      device_read_bps:
        - path: "8:0"
          rate: 1048576
```

References:

- Compose service `blkio_config`: <https://docs.docker.com/reference/compose-file/services/#blkio_config>
- Existing apple/container issue: [apple/container#1512](https://github.com/apple/container/issues/1512)
- Existing apple/container PR by Chris George: [apple/container#1595](https://github.com/apple/container/pull/1595)
- Required lower-level runtime support: [apple/containerization#739](https://github.com/apple/containerization/pull/739)
- Current fork representation: [stephenlclarke/containerization](https://github.com/stephenlclarke/containerization/tree/main)

## Current container-compose behavior

The normalizer preserves `blkio_config`, and the orchestrator maps the supported fields against the block I/O runtime contract represented by [apple/container#1595](https://github.com/apple/container/pull/1595).

With this change, `container-compose` supports the plugin-owned half of the surface:

- compose-go normalized `blkio_config.weight` is preserved.
- `weight_device`, `device_read_bps`, `device_write_bps`, `device_read_iops`, and `device_write_iops` are preserved with path/rate values.
- `up`, `create`, and one-off `run` project typed OCI block I/O data. The current live execution path still renders repeatable `container run/create --blkio` arguments using the key-value syntax from [apple/container#1595](https://github.com/apple/container/pull/1595) while typed service creation is being wired.
- Invalid weights, empty device paths, comma-containing device paths, and non-integer throttle rates are rejected before runtime commands.

## Likely owner

`container-compose` owns the Compose model normalization, validation, and typed block I/O projection.

`apple/container` owns device path resolution, major/minor translation, cgroup application, and the dependency on the underlying `containerization` blockIO API. This repository should track and depend on [apple/container#1595](https://github.com/apple/container/pull/1595), not open a duplicate runtime PR. The local stack pins the `stephenlclarke/containerization` revision representing [apple/containerization#739](https://github.com/apple/containerization/pull/739) so the Compose mapping can be tested while upstream review continues.

## Minimal example

```yaml
name: blkio-demo

services:
  db:
    image: postgres:16
    blkio_config:
      weight: 500
      weight_device:
        - path: "8:0"
          weight: 700
      device_read_bps:
        - path: "8:0"
          rate: 1048576
```

Expected fork-backed runtime behavior when the runtime includes [apple/container#1595](https://github.com/apple/container/pull/1595):

- `container-compose` currently renders `--blkio weight=500` through the command-vector bridge.
- `container-compose` currently renders `--blkio device=8:0,weight=700` through the command-vector bridge.
- `container-compose` currently renders `--blkio device=8:0,read-bps=1048576` through the command-vector bridge.
- `apple/container` validates and applies the Linux block I/O runtime data.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
