# Support `compose build --builder NAME`

## Summary

`container compose build --builder NAME [SERVICE...]` should select the requested builder instead of rejecting every non-default builder name.

Docker Compose documents `build --builder string` for selecting a Buildx builder. Buildx also exposes named builders as first-class builder instances. The stephenlclarke fork-backed `container` lane can satisfy the same workflow by mapping `default` to the ordinary `buildkit` builder container and non-default names to separate `buildkit-NAME` builder containers.

## Current Gap

Before this slice, `container-compose` accepted only `--builder default` and rejected non-default names before build, check, or print behavior could run. That kept scripts with named Docker Compose builders from using the fork-backed build path even when the selected builder could be represented by a separate local BuildKit container.

## Upstream Check

- Docker Compose's CLI reference documents `docker compose build --builder`.
- Docker Buildx documents named builder selection through `--builder` / builder instances.
- `docker/compose#10664` is the historical Compose issue for adding builder selection to `compose build`.
- `apple/container-builder-shim#74` discusses exposing BuildKit so Buildx can register a remote builder. That is useful upstream context, but this slice can stay smaller by adding the builder selection primitive to the stephenlclarke fork-backed `container` CLI and forwarding from `container-compose`.

## Expected Behavior

- `container compose help build` marks `--builder` supported.
- `container compose build --builder default [SERVICE...]` forwards `--builder default` to `container build`.
- `container compose build --builder NAME [SERVICE...]` forwards `--builder NAME` to `container build`.
- `container compose build --builder NAME --print [SERVICE...]` renders the same Buildx bake JSON shape as Docker Compose; builder selection does not appear in bake JSON.
- Live named-builder builds use the matching fork-backed `container` runtime and builder image.

## Runtime Dependency

Live execution requires the matching stephenlclarke fork-backed `container` that supports `container build --builder NAME` and `container builder ... --builder NAME`.
