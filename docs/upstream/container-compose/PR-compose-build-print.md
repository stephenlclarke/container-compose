# Support `compose build --print`

## Summary

This change fills a `compose build` partial-support gap:

- Stops rejecting `build --print`.
- Marks `--print` as supported in help.
- Adds `printBake` to `ComposeBuildOptions`.
- Renders deterministic Buildx bake JSON for selected build services.
- Reuses the existing build selection and `--with-dependencies` ordering.
- Maps file and CLI build args, build secrets, cache hints, labels, tags, target stage, platforms, pull/no-cache, inline Dockerfile, and output mode into bake targets.
- Exits before `container build` or image push side effects.

## Rationale

`build --print` is a render-only Compose feature. It can be implemented entirely inside `container-compose` by translating the normalized Compose build model into the Buildx bake JSON shape. That keeps this slice local, reviewable, and independent of apple/container runtime changes.

The renderer intentionally keeps the same unsupported-build-field validation as the existing build path so the printed bake file does not claim support for build features this plugin does not yet preserve or execute.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'buildPrintRendersBakeTargetsWithoutBuildSideEffects|buildPrintRendersInlineDockerfile|buildPrintRejectsEmptyBuildArgumentNames|buildPrintOptionIsShownAsSupported|buildPrintFlagParses'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeBuildPrintRendersBakeFileFromComposeFile
git diff --check
```

Before release promotion, run the broader local gate:

```sh
make check
make cli-smoke-built
make coverage-check
```

## Compatibility Notes

- `--push` renders registry output only for services that declare an explicit image reference. Generated local build tags remain local output, matching the current push behavior.
- `--memory` remains accepted by the build command but is omitted from bake output, matching Docker Compose's BuildKit behavior.
- `--builder` is covered by the later named-builder slice. `--check` is rendered with `call: "lint"` and no output by the later compose build-check slice.
- `--provenance` and `--sbom` are rendered in bake output by the later compose build attestations slice.
- `--ssh` is supported through the normal build path; default agent forwarding, non-default `id=/path` host sockets, and multiple distinct host sockets are covered by the dedicated build SSH slice.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `db75b0af6aecb7f87ad653070f3be10eb2a79a6b`.
