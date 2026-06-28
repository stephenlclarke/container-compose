# Accept `compose build --provenance=false --sbom=false`

> Superseded by [PR-compose-build-attestations.md](./PR-compose-build-attestations.md), which adds support for true and configured provenance/SBOM attestation requests.

## Summary

This change accepts Docker Compose's explicit attestation disable forms for `compose build`:

- Treats `--provenance=false`, `--provenance=0`, and `--provenance=no` as no-op opt-outs.
- Treats `--sbom=false`, `--sbom=0`, and `--sbom=no` as no-op opt-outs.
- Left true or configured attestation requests for a later backend-backed support slice.
- Documented the false forms in CLI help.
- Adds focused parser/help, runtime build-print, and Makefile smoke coverage.

## Rationale

At the time of this slice, the build implementation could not emit Docker-compatible provenance or SBOM attestations. Explicit false values did not require attestation support; they meant the caller was disabling those outputs.

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
- True or configured attestation requests are covered by the later compose build attestations slice.
