# Support `compose build` attestations

## Summary

This change fills the Compose build attestation gap:

- Stops rejecting true or configured `build --provenance` and `build --sbom` values.
- Marks `--provenance` and `--sbom` as supported in CLI help.
- Adds CLI attestation values to `ComposeBuildOptions`.
- Normalizes service `build.provenance` and `build.sbom` entries from compose-go into `ComposeBuild`.
- Forwards resolved attestation values to `container build --provenance` and `--sbom`.
- Renders supported attestation values in `compose build --print` Buildx bake JSON.
- Keeps explicit false, zero, and no values as opt-outs.

## Rationale

The customized container backend now forwards BuildKit attestation frontend attributes through the builder shim. `container-compose` can therefore support Docker Compose build attestation declarations by preserving the normalized values and passing them through to the existing build command path.

CLI values are applied after compose-file values, which gives users an override path for local builds and mirrors the existing CLI-over-file behavior used by build args and SSH.

## Verification

Run focused local validation:

```sh
(cd Tools/compose-normalizer && go test ./...)
swift test --disable-automatic-resolution --filter 'buildPrintOptionIsShownAsSupported|buildPrintFlagParses'
swift test --disable-automatic-resolution --filter 'buildOptionsAddCLIBuildArgsAndMemory|buildPrintRendersBakeTargetsWithoutBuildSideEffects|groupedModelInitializersPreserveFlatNormalizedFields'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeBuildPrintRendersBakeFileFromComposeFile
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

- `--provenance=false`, `--provenance=0`, `--provenance=no`, `--sbom=false`, `--sbom=0`, and `--sbom=no` remain no-op opt-outs.
- Non-false attestation values require the customized `container` and `container-builder-shim` build path that forwards BuildKit `attest:*` frontend attributes.
- `--builder` and `--check` remain unsupported.
