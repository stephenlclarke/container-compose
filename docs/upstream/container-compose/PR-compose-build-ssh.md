# Support `compose build --ssh` and `build.ssh`

## Summary

This change fills the Compose build SSH forwarding gap:

- Stops rejecting `compose build --ssh`.
- Marks `build --ssh` as partially supported in help.
- Adds repeated CLI SSH values to `ComposeBuildOptions`.
- Normalizes service `build.ssh` entries from compose-go into `ComposeBuild.ssh`.
- Forwards merged SSH values to `container build --ssh`.
- Renders SSH values in `compose build --print` Buildx bake JSON.
- Keeps unsupported-build-field validation for unrelated advanced build options.

## Rationale

The matching container backend now accepts `container build --ssh` and forwards SSH metadata into the builder session. `container-compose` can therefore support Docker Compose build SSH declarations by preserving those values and passing them through to the existing build command path.

CLI values are applied after compose-file values and replace any file value with the same SSH id, which gives users an override path for local agent/socket differences without editing `compose.yml`.

Default SSH agent forwarding is live-tested end to end. One explicit non-default `id=/path/to/socket` value is now live-tested through the fork-backed container backend. Multiple distinct host socket paths still need a runtime follow-up before the option can be marked fully supported.

## Verification

Run focused local validation:

```sh
(cd Tools/compose-normalizer && go test ./...)
swift test --disable-automatic-resolution --filter 'buildPrintOptionIsShownAsSupported|buildPrintFlagParses'
swift test --disable-automatic-resolution --filter 'buildOptionsAddCLIBuildArgsAndMemory|buildPrintRendersBakeTargetsWithoutBuildSideEffects|groupedModelInitializersPreserveFlatNormalizedFields'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeBuildPrintRendersBakeFileFromComposeFile
CONTAINER_BIN=/Users/sclarke/github/container/bin/container COMPOSE_TEST_BINARY=/Users/sclarke/github/container-compose/.build/debug/compose CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeBuildForwardsDefaultSSHFromComposeFileAndCLI
CONTAINER_BIN=/Users/sclarke/github/container/bin/container COMPOSE_TEST_BINARY=/Users/sclarke/github/container-compose/.build/debug/compose CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeBuildForwardsExplicitSSHSocketFromCLI
make ci
make cli-smoke-built
git diff --check
```

Before release promotion, run the broader local gate:

```sh
make check
make cli-smoke-built
make coverage-check
```

## Compatibility Notes

- This implements SSH forwarding declarations only for the build path.
- Default SSH agent forwarding and one explicit `id=/path/to/socket` host Unix socket are live-tested.
- Multiple distinct host socket paths need backend support for arbitrary host socket attachments.
- `--builder`, `--check`, true provenance output, and true SBOM output remain unsupported.
- Runtime support requires a container build backend that accepts `container build --ssh`.
