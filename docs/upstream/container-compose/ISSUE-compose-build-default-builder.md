# Accept `compose build --builder default`

## Summary

`container compose build --builder default [SERVICE...]` should follow the normal local build path instead of failing as unsupported.

Status update: this default-builder slice was later superseded by named-builder support. Current `container-compose` forwards both `default` and non-default builder names to the fork-backed `container build` backend.

Docker Compose exposes `--builder` to select a Buildx builder. At the time of this slice, `container-compose` had one configured `apple/container` builder, so the Docker default-builder spelling was compatible as a no-op while arbitrary named builders still implied a backend selection primitive that did not exist yet.

## Current Gap

Before this slice, the parser accepted `--builder` for help-surface parity, but execution rejected every value before `compose build --print`, `--check`, or build execution could run.

That meant scripts that pass Docker Compose's default builder explicitly failed even though they were not asking for a different backend.

## Docker Compose Reference

- Docker Compose build CLI reference documents `--builder string`.
- [docker/compose#10664](https://github.com/docker/compose/issues/10664) tracks the upstream feature request that added named builder selection to Compose build.

Local parity on this MacBook Pro:

```sh
docker-compose build --builder default --print api
```

accepted the flag and rendered Buildx bake JSON without needing a Docker daemon.

## Historical Expected Behavior

- `container compose help build` marks `--builder` partially supported.
- `container compose build --builder default [SERVICE...]` follows the same path as `build [SERVICE...]`.
- `container compose build --builder default --print [SERVICE...]` renders the same bake JSON as the default builder path.
- At the time of the default-builder slice, `container compose build --builder NAME [SERVICE...]` rejected non-default names before runtime side effects.

## Superseded Gap

Full `--builder NAME` parity is no longer blocked in the stephenlclarke fork-backed lane; non-default names now map to separate named BuildKit builder containers through `container build --builder`.
