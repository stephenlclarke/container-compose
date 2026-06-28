# Accept `compose build --provenance=false --sbom=false`

## Summary

This change accepts Docker Compose's explicit attestation disable forms for `compose build`:

- Treats `--provenance=false`, `--provenance=0`, and `--provenance=no` as no-op opt-outs.
- Treats `--sbom=false`, `--sbom=0`, and `--sbom=no` as no-op opt-outs.
- Keeps true or configured attestation requests blocked with the existing unsupported-feature errors.
- Marks `build --provenance` and `build --sbom` as partially supported in CLI help and documents the false forms.
- Adds focused parser/help, runtime build-print, and Makefile smoke coverage.

## Rationale

The current build implementation uses apple/container's build path and cannot emit Docker-compatible provenance or SBOM attestations. Explicit false values do not require attestation support; they mean the caller is disabling those outputs.

Rejecting false values makes otherwise portable Docker Compose invocations fail before the normal build or build-print path can run.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'buildPrintOptionIsShownAsSupported|buildPrintFlagParses'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeBuildPrintRendersBakeFileFromComposeFile
git diff --check
```

Before pushing the main-only compatibility slice, run the broader local gate:

```sh
make check
make cli-smoke-built
```

## Compatibility Notes

- Explicit false attestation options are accepted as no-ops.
- True or configured attestation requests remain unsupported until the build backend exposes compatible provenance and SBOM output.
- The command remains partially supported.
