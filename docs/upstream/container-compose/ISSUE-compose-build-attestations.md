# Support `compose build --provenance` and `--sbom`

## Summary

`container compose build --provenance VALUE --sbom VALUE SERVICE` should pass supported Docker Compose attestation requests through to the customized `container build` backend instead of treating true or configured values as unsupported.

Docker Compose exposes provenance and SBOM controls for BuildKit attestations. The current customized container stack can now forward BuildKit `attest:provenance` and `attest:sbom` frontend attributes, so the compose plugin should preserve compose-file `build.provenance` and `build.sbom`, accept CLI overrides, and render Buildx bake `attest` entries for `build --print`.

## Acceptance Criteria

- `container compose build --provenance=true SERVICE` follows the normal build path and forwards `--provenance true`.
- `container compose build --provenance=mode=max SERVICE` forwards `--provenance mode=max`.
- `container compose build --sbom=true SERVICE` follows the normal build path and forwards `--sbom true`.
- `container compose build --provenance=false --sbom=false SERVICE` remains a no-op opt-out for those attestation controls.
- Compose-file `build.provenance` and `build.sbom` values are normalized and preserved.
- CLI attestation values override compose-file attestation values.
- `container compose build --print` emits Buildx bake `attest` entries such as `type=provenance,mode=max` and `type=sbom`.
- `container compose help build` marks `--provenance` and `--sbom` as supported.

## Notes

This depends on the customized `container` and `container-builder-shim` forwarding BuildKit attestation frontend attributes. Apple upstream compatibility remains isolated to the metadata pass-through shape so the change can be reviewed independently.
