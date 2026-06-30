# Preserve bind create_host_path behavior

## Compose surface

`services.<name>.volumes[].bind.create_host_path`

## Docker Compose v2 behavior

Docker Compose V2 treats bind mounts as Docker bind mounts with an effective host-path creation policy. Short syntax and long syntax without an explicit `bind.create_host_path` default to host-path creation. Explicit `bind.create_host_path: false` preserves a stricter policy: a missing source path is rejected instead of being created.

Upstream context checked before this slice:

- `compose-go` v2.12.1 defaults missing bind `create_host_path` to true in `transform/volume.go`.
- `docker/compose#13602` tracks a bug report around `bind.create_host_path: false` being ignored in at least one path.
- `docker/compose#13889` proposes explicit validation for missing bind sources when `create_host_path` is false.
- Apple/container searches for bind mount source handling found relative-path and mount support issues such as `apple/container#565`, `apple/container#618`, and `apple/container#1837`, but no Docker Compose `create_host_path` policy primitive.

## Current container-compose behavior

Before this slice, the Go normalizer discarded the bind `create_host_path` bit. Swift orchestration then treated a missing bind source the same whether the Compose file defaulted host-path creation or explicitly disabled it. With Apple/container, a missing bind source fails during runtime handoff, so default bind mounts could fail even though Docker Compose accepts them.

Minimal affected example:

```yaml
services:
  api:
    image: alpine:3.20
    volumes:
      - type: bind
        source: ./required
        target: /data
        bind:
          create_host_path: false
```

## Likely owner

container-compose design gap.

This does not require a new Apple runtime primitive. The plugin can preserve compose-go's effective bind policy, reject missing false-policy sources before runtime side effects, and create true/default-policy source directories before handing the bind mount to Apple/container.

## Expected behavior

- `container compose config --format json` preserves the normalized bind `create_host_path` policy for orchestration.
- `container compose up`, `create`, and `run` reject missing bind sources when `bind.create_host_path: false`.
- Default or true `bind.create_host_path` bind sources are created as host directories before Apple runtime create/run handoff.
- Advanced bind options such as propagation, recursive mode, and SELinux labels remain separate Apple runtime gaps.
