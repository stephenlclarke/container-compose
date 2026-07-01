# Support bind propagation mount options

## Compose surface

`services.<name>.volumes[].bind.propagation`

## Docker Compose v2 behavior

Docker Compose V2 preserves long-form bind propagation values in `config --format json` and hands them to Docker Engine as bind propagation options. Valid values are `private`, `rprivate`, `shared`, `rshared`, `slave`, and `rslave`.

Minimal affected example:

```yaml
services:
  node-exporter:
    image: prom/node-exporter
    volumes:
      - type: bind
        source: /
        target: /host
        read_only: true
        bind:
          propagation: rslave
```

## Current container-compose behavior

Before this slice, the Go normalizer marked `bind.propagation` as an unsupported mount field. `container compose up` therefore failed before command rendering even though the current Apple runtime path can carry generic mount options through short `--volume` arguments.

## Likely owner

container-compose design gap.

`containerization` already preserves `Mount.options` through attached filesystems and OCI bind mounts. `apple/container` already accepts short `--volume` option strings and forwards them to `Filesystem.options`. The plugin can therefore preserve Compose bind propagation and render it as a runtime mount option without adding a new lower-runtime primitive.

## Expected behavior

- `container compose config --format json` preserves `bind.propagation`.
- `container compose up`, `create`, and `run` accept the six Docker Compose bind propagation values.
- Runtime command rendering appends propagation to the short volume option field, for example `--volume /host:/container:ro,rslave`.
- Unsupported advanced bind fields such as `bind.recursive` and SELinux labels remain blocked until the Apple runtime exposes compatible primitives.
