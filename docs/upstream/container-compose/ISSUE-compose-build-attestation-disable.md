# Accept `compose build --provenance=false --sbom=false`

## Summary

`container compose build --provenance=false --sbom=false SERVICE` should build normally instead of failing as an unsupported attestation request.

Docker Compose exposes provenance and SBOM options as attestation controls. This plugin cannot emit compatible provenance or SBOM attestations through the current apple/container build path, but explicit false values are opt-outs and should behave like the options were not set.

## Acceptance Criteria

- `container compose build --provenance=false SERVICE` follows the normal build path.
- `container compose build --sbom=false SERVICE` follows the normal build path.
- `container compose build --provenance=true SERVICE` still reports the unsupported provenance attestation feature.
- `container compose build --sbom=true SERVICE` still reports the unsupported SBOM attestation feature.
- `container compose help build` marks `--provenance` and `--sbom` as partially supported and documents the false disable forms.
- Focused tests cover parser integration, help color/status, Makefile smoke, and a compose.yml runtime dry-run/build-print smoke.

## Notes

This does not implement attestation generation. It only accepts explicit disable forms that request no provenance or SBOM output.
