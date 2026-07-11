# Accept default `compose build --builder`

Superseded note: a later named-builder slice forwards both `default` and non-default builder names to the fork-backed `container build` backend.

## Summary

- Accepted `build --builder default` as the local single-builder selection.
- Was originally limited to rejecting non-default builder names with a precise unsupported-feature message.
- Marked `--builder` as partially supported in the compatibility help surface.
- Left the `container build` command line unchanged because the backend used one configured builder at the time.
- Added focused unit/runtime smoke coverage and documented the then-remaining named-builder gap.

## Rationale

Docker Compose's `--builder` flag selects a Buildx builder. At the time of this slice, `container-compose` did not expose multiple builders, but `default` was the Docker spelling for the ordinary builder path and could be treated as compatible with the single local `apple/container` builder.

Rejecting all `--builder` values made default-builder scripts fail unnecessarily. Accepting only `default` improved parity before the later named-builder slice added `--builder NAME` support for the stephenlclarke fork-backed lane.

## Validation

```sh
docker-compose build --builder default --print api
swift test --disable-automatic-resolution --filter 'buildAcceptsDefaultBuilderAsLocalSingleBuilderSelection|buildRejectsNonDefaultBuildersBeforeEmittingCommands'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeBuildPrintRendersBakeFileFromComposeFile
make docker-compose-build-builder-parity
```

## Superseded Gaps

- `build --builder NAME` for non-default names is supported in the stephenlclarke fork-backed lane by selecting a separate named BuildKit builder container.
