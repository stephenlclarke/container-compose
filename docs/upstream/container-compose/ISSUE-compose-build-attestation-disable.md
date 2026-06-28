# Accept `compose build --provenance=false --sbom=false`

> Superseded by [ISSUE-compose-build-attestations.md](./ISSUE-compose-build-attestations.md), which adds support for true and configured provenance/SBOM attestation requests.

## Summary

`container compose build --provenance=false --sbom=false SERVICE` should build normally instead of failing as an unsupported attestation request.

Docker Compose exposes provenance and SBOM options as attestation controls. This earlier slice accepted explicit false opt-outs before the customized container build backend could forward compatible provenance and SBOM attestation attributes.

## Acceptance Criteria

- `container compose build --provenance=false SERVICE` follows the normal build path.
- `container compose build --sbom=false SERVICE` follows the normal build path.
- `container compose build --provenance=true SERVICE` is covered by the later attestation support slice.
- `container compose build --sbom=true SERVICE` is covered by the later attestation support slice.
- `container compose help build` documents the false disable forms.
- Focused tests cover parser integration, help color/status, Makefile smoke, and a compose.yml runtime dry-run/build-print smoke.

## Notes

This document records the original false-opt-out compatibility slice. Current support is tracked in the compose build attestations issue and PR notes.
