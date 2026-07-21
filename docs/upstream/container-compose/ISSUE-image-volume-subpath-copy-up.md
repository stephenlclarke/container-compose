# Compose volume parity: do not copy image data into an existing `volume.subpath`

## Compose surface

Dockerfile-declared `VOLUME` destinations mounted through Compose long-form `volume.subpath` in `up`, `create`, and one-off `run`.

```dockerfile
VOLUME ["/image-data"]
```

```yaml
services:
  api:
    image: example/api
    volumes:
      - type: volume
        source: data
        target: /image-data
        volume:
          subpath: nested
```

## Problem

The image-volume copy-up policy previously treated every volume covering a declared image target as an initialization candidate, then rejected a mount with `volume.subpath`. That diagnostic was incorrect: Docker requires the selected volume directory to exist before mounting it. The parent volume is therefore not a fresh image-copy-up destination, and Docker leaves the mounted subdirectory's contents unchanged.

## Implemented behavior

The Compose policy now recognizes a non-empty `volume.subpath` before selecting a Dockerfile-declared image target for initialization. It leaves the parent volume unchanged, renders the existing typed runtime mount, and lets the generic runtime validate the selected directory. Missing, traversal, symlink-escape, and non-directory subpaths continue to fail at the generic mount boundary.

The implementation deliberately does not create the directory or copy the image subtree into it. Both would diverge from Docker's pre-existing-subpath contract and could overwrite retained data.

## Apple-shaped boundary

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Secure guest-side resolution beneath a mounted local volume. |
| `apple/container` | Generic `--mount …,volume-subpath=<directory>` parsing and runtime projection. |
| `container-compose` | Docker-specific decision to skip image copy-up once a Compose subpath is present. |

No fork change is required for this slice. The existing generic runtime work remains separately reviewable and contains no Compose types, labels, or lifecycle behavior.

## Source map and prerequisites

- `stephenlclarke/containerization` secure subpath primitive: PR #9, documented by [PR-volume-subpath.md](PR-volume-subpath.md).
- `stephenlclarke/container` typed mount projection: PR #21, documented by [PR-volume-subpath.md](PR-volume-subpath.md).
- Compose policy: `Sources/ComposeCore/ComposeOrchestratorImageVolumes.swift`.
- Compose regression coverage: `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift`.
- Docker Compose V2 fixture and live-runtime coverage: `Tools/parity/fixtures/image-volumes/compose.yaml` and `Tools/parity/check-compose-image-volumes.sh`.

## Acceptance criteria

- Compose renders `volume-subpath=nested` without an unsupported-feature error.
- Docker Compose V2 and the Compose normalized model preserve the same subpath declaration.
- A prepared subpath mounted on an image `VOLUME` does not receive the image seed, while another declared image target is still initialized.
- The optional matched macOS runtime leg runs the same assertions without creating or seeding the subpath.
- Generic copy-up for a mount outside image-declared `VOLUME` targets remains explicitly tracked as a separate gap.
