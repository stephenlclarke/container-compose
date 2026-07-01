# Compose compatibility gap: device cgroup rules

## Compose surface

`services.<name>.device_cgroup_rules`

## Docker Compose v2 behavior

Docker Compose accepts Linux device cgroup rule strings and preserves them in normalized config. On Docker Engine, the values are projected to `HostConfig.DeviceCgroupRules` for service containers.

```yaml
services:
  api:
    image: alpine:3.20
    device_cgroup_rules:
      - "c 1:3 mr"
      - "a *:* rwm"
```

References:

- Compose service `device_cgroup_rules`: <https://docs.docker.com/reference/compose-file/services/#device_cgroup_rules>
- Docker run `--device-cgroup-rule`: <https://docs.docker.com/reference/cli/docker/container/run/#device-cgroup-rule>
- Host-device and GPU passthrough remain separate upstream gaps: [apple/container#1683](https://github.com/apple/container/issues/1683), [apple/container#1680](https://github.com/apple/container/issues/1680), [apple/container#1511](https://github.com/apple/container/issues/1511), [apple/container#640](https://github.com/apple/container/issues/640), [apple/containerization#74](https://github.com/apple/containerization/issues/74), and [apple/containerization#480](https://github.com/apple/containerization/issues/480).

## Current container-compose behavior

Before this change, `device_cgroup_rules` was grouped with host device passthrough and GPU request fields, so the orchestrator rejected any service that declared it before runtime side effects.

With this change, `container-compose` supports the cgroup-rule subset:

- compose-go normalized `device_cgroup_rules` values remain visible through `compose config --format json` as the internal normalized `deviceCgroupRules` key.
- `up`, `create`, and one-off `run` validate rule syntax before runtime commands.
- The command-vector bridge renders repeatable `container run/create --device-cgroup-rule` arguments for the fork-backed runtime.
- Invalid rule strings fail before images, networks, volumes, or containers are created.

## Likely owner

`container-compose` owns Compose model validation, Docker-compatible rule-string acceptance, dry-run rendering, and Docker Compose parity tests.

`apple/container` owns the native CLI/API entry point and typed runtime-data bridge for Linux device cgroup rules. `apple/containerization` owns projecting those rules into the generated OCI runtime spec. Service `devices` is handled by the later supported Linux VM device slice; `gpus` still needs a separate device-passthrough primitive.

## Minimal example

```yaml
services:
  api:
    image: alpine:3.20
    command: ["true"]
    device_cgroup_rules:
      - "c 1:3 mr"
      - "a *:* rwm"
```

Expected fork-backed behavior:

- `container compose config --format json` preserves the rule values in the normalized service model.
- `container compose --dry-run up api` emits `--device-cgroup-rule c 1:3 mr` and `--device-cgroup-rule a *:* rwm`.
- `container compose --dry-run create api` emits the same rules.
- `container compose --dry-run run api true` emits the same rules.

## Code of Conduct and documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked `STATUS.md` and relevant upstream docs.
