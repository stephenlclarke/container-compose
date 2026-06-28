# Accept `compose build --builder default`

## Summary

`container compose build --builder default [SERVICE...]` should follow the normal local build path instead of failing as unsupported.

Docker Compose exposes `--builder` to select a Buildx builder. `container-compose` currently has one configured `apple/container` builder, so the Docker default-builder spelling is compatible as a no-op. Arbitrary named builders still imply a backend selection primitive that does not exist yet.

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

## Expected Behavior

- `container compose help build` marks `--builder` partially supported.
- `container compose build --builder default [SERVICE...]` follows the same path as `build [SERVICE...]`.
- `container compose build --builder default --print [SERVICE...]` renders the same bake JSON as the default builder path.
- `container compose build --builder NAME [SERVICE...]` keeps failing before runtime side effects for non-default names.

## Remaining Gap

Full `--builder NAME` parity remains blocked until the build backend exposes Docker-compatible named builder selection.
