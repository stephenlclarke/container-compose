# Accept default `compose build --builder`

## Summary

- Accepts `build --builder default` as the local single-builder selection.
- Keeps non-default builder names rejected with a precise unsupported-feature message.
- Marks `--builder` as partially supported in the compatibility help surface.
- Leaves the `container build` command line unchanged because `apple/container` already uses its configured builder.
- Adds focused unit/runtime smoke coverage and documents the remaining named-builder gap.

## Rationale

Docker Compose's `--builder` flag selects a Buildx builder. `container-compose` does not expose multiple builders today, but `default` is the Docker spelling for the ordinary builder path and can be treated as compatible with the single local `apple/container` builder.

Rejecting all `--builder` values made default-builder scripts fail unnecessarily. Accepting only `default` improves parity without pretending named builder selection exists.

## Validation

```sh
docker-compose build --builder default --print api
swift test --disable-automatic-resolution --filter 'buildAcceptsDefaultBuilderAsLocalSingleBuilderSelection|buildRejectsNonDefaultBuildersBeforeEmittingCommands'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeBuildPrintRendersBakeFileFromComposeFile
make docker-compose-build-builder-parity
```

## Remaining Gaps

- `build --builder NAME` for non-default names remains unsupported until a compatible named-builder primitive exists in the backend.
