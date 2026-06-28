# Support `compose build --check`

## Summary

`container compose build --check` should behave like Docker Compose V2: validate selected service build configuration through BuildKit lint/check, report warnings or Dockerfile errors, and avoid image build/export/push side effects.

## Current Gap

Before this slice, the CLI parser accepted `--check` only so help/parity could display the Docker Compose option, but command execution rejected it as unsupported.

## Docker Compose Reference

Docker Compose added `build --check` in [docker/compose#12765](https://github.com/docker/compose/pull/12765), closing [docker/compose#12749](https://github.com/docker/compose/issues/12749). Docker's build path sets Bake `call: "lint"` and clears outputs when check mode is enabled.

## Expected Behavior

- `container compose help build` marks `--check` supported.
- `container compose build --check [SERVICE...]` forwards `--check` to `container build` for selected buildable services.
- `--check --push` does not push images because check mode does not create image outputs.
- `container compose build --print --check` renders Buildx-compatible JSON with `call: "lint"` and no image output for selected targets.
- `--builder` remains unsupported until Apple/container exposes a named builder selection primitive.

## Runtime Dependency

Live execution requires the matching fork-backed `stephenlclarke/container` and `container-builder-shim` support documented in `docs/upstream/apple-container/ISSUE-container-build-check.md` and `docs/upstream/apple-container/PR-container-build-check.md`.
