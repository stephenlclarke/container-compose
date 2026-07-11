# feat(build): add Dockerfile check mode

## Summary

- Adds `container build --check`.
- Forwards a `check` metadata key to the builder shim.
- Runs BuildKit Dockerfile lint/check in the shim without image exporters.
- Emits lint output over the existing stderr/progress stream.
- Skips image unpack/tag/load on successful check mode.

## Motivation

Docker Compose V2 supports `docker compose build --check` by routing Buildx Bake through BuildKit's lint call (`call: "lint"`) with no image outputs. `container-compose` needs the same lower-level primitive before it can support Compose `build --check` with Docker-compatible side-effect behavior.

## Implementation Notes

- The builder shim reuses its existing Dockerfile conversion setup so lint mode sees the same build args, target, platforms, resolver, local named contexts, labels, SSH, and secret session inputs as the real build path.
- Check mode leaves `SolveOpt.Exports` empty and avoids creating export tar paths.
- Lint warnings or lint build errors return a nonzero command result.
- Clean checks print a short success message and do not unpack any image archive.

## Validation

Run from the matching local checkouts:

```sh
cd /Users/sclarke/github/container-builder-shim
go test ./...

cd /Users/sclarke/github/container
swift test --disable-automatic-resolution --filter 'BuildCommandTests|BuilderMetadataTests'

cd /Users/sclarke/github/container-compose
make docker-compose-build-check-parity
```

For a live fork-backed runtime smoke, install the matching `stephenlclarke/container` build and builder image, then run:

```sh
CONTAINER_COMPOSE_BUILD_CHECK_LIVE=1 make docker-compose-build-check-parity
```

## Related

- Docker Compose issue: [docker/compose#12749](https://github.com/docker/compose/issues/12749)
- Docker Compose implementation: [docker/compose#12765](https://github.com/docker/compose/pull/12765)

## Commit Tracking

- Apple-facing `stephenlclarke/container` implementation:
  `0c9445db4e4b9320199120345258e15e927aeebe` (`feat(build): add check
  flag`).
- The required lower builder implementation is a separate Apple repository
  slice documented in
  [PR-build-check.md](../apple-container-builder-shim/PR-build-check.md).
