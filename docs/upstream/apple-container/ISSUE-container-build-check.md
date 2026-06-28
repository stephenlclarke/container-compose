# Add `container build --check`

## Summary

`container build` should expose a Docker-compatible build-check mode that validates Dockerfile build configuration through BuildKit lint without exporting or unpacking an image.

## Compatibility Need

Docker Compose V2 added `docker compose build --check` in [docker/compose#12765](https://github.com/docker/compose/pull/12765), closing [docker/compose#12749](https://github.com/docker/compose/issues/12749). Docker's implementation maps the Buildx Bake target to `call: "lint"` and omits image outputs, so warnings or Dockerfile parse errors return a nonzero status before any image export side effects.

`container-compose` needs the same runtime primitive so `compose build --check` can be a true lint/check operation instead of a plugin-only placeholder.

## Proposed Behavior

- `container build --check [OPTIONS] CONTEXT` runs BuildKit Dockerfile lint/check using the same build context, Dockerfile, target, build args, labels, platforms, SSH, secrets, cache inputs, and local resolver inputs as a normal build.
- Check mode emits BuildKit lint text to stderr.
- Check mode exits nonzero when BuildKit reports warnings or Dockerfile build errors.
- Check mode does not configure exporters, write an OCI archive, load an image, tag images, or unpack image content.
- A successful clean check prints a short success row and exits zero.

## Fork Implementation

Local fork support is split across:

- `stephenlclarke/container-builder-shim`: adds `check` metadata parsing, skips BuildKit exporters in check mode, calls `dockerfile2llb.DockerfileLint`, and reports the lint status through the existing stderr stream.
- `stephenlclarke/container`: adds `container build --check`, forwards `check` metadata to the builder shim, and returns before image unpacking on success.

## Acceptance Criteria

- `container build --help` lists `--check`.
- `container build --check` reports BuildKit lint warnings and exits nonzero without creating/loading an image.
- Existing normal build behavior and exporters are unchanged when `--check` is absent.
- Unit tests cover CLI parsing and metadata forwarding.
- Local non-CI parity checks cover the Docker Compose `build --check` behavior used by `container-compose`.
