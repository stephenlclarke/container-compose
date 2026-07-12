<!-- markdownlint-disable MD013 -->

# [Request]: Build matched init images for source-control containerization dependencies

## Feature or enhancement request details

`scripts/install-init.sh` should install an init image built from the same `containerization` source used by the current `container` build whenever that dependency is source-backed or explicitly supplied by release automation. The image reference should default to `vminit:latest` and support a deterministic override for isolated stack/parity lanes.

SwiftPM reports `version: "unspecified"` for local edits and source-control dependencies pinned to a branch. Local edits can be built in place. Read-only source-control checkouts under `.build/checkouts/` cannot be built in place, but skipping them leaves the host API and guest `vminitd` on different revisions when a source-backed stack adds new runtime RPCs.

The script should support deterministic source path and image-reference overrides for stack/release automation and should copy read-only SwiftPM checkouts to a temporary writable directory before building the init image.

## Acceptance Criteria

- `CONTAINERIZATION_INIT_SOURCE_PATH` builds and installs the configured init image from the supplied checkout.
- `CONTAINER_INIT_IMAGE_NAME` selects the image reference to build and install, defaulting to `vminit:latest`.
- A writable local `containerization` edit builds and installs the configured init image.
- A read-only branch-pinned SwiftPM checkout is copied to a temporary writable directory before `make init`.
- The script does not modify `.build/checkouts/containerization` in place.
- A missing path fails with a clear diagnostic.
- Paths containing spaces remain quoted.
- Temporary init image archives and copied source directories are removed after the script exits.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
