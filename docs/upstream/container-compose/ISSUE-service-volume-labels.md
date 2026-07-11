# Support service long-form volume labels

## Compose surface

`services.<name>.volumes[].volume.labels`

## Docker Compose v2 behavior

Docker Compose V2 preserves service long-form `volume.labels` in `config --format json`.

Runtime behavior is intentionally narrower than config preservation:

- Named service mount labels stay metadata on the service mount and are not applied to the named Docker volume resource.
- Anonymous service mount labels are applied to the anonymous Docker volume created for that container.
- Top-level `volumes.<name>.labels` remain the label source for named volume resources.

Upstream context checked before this slice:

- Searches across `docker/compose`, `compose-spec/compose-spec`, and `compose-spec/compose-go` did not find direct open issues or PRs for service `volume.labels`.
- Searches across `apple/container` did not find direct open label issues. Relevant merged runtime support is `apple/container#768` for anonymous volumes and `apple/container#769` for implicit named volume creation.
- Closed `apple/container#398` is the earlier Compose plugin proposal and keeps the natural ownership for this behavior in the plugin layer.

## Current container-compose behavior

Before this slice, the Go normalizer marked `volume.labels` as an unsupported mount field. That rejected Compose files that Docker Compose accepts, even though the current stephenlclarke runtime path can create labeled volumes through `container volume create --label`.

Minimal affected example:

```yaml
services:
  api:
    image: alpine:3.20
    volumes:
      - type: volume
        target: /scratch
        volume:
          labels:
            com.example.owner: platform
```

## Likely owner

container-compose design gap.

This does not require a new Apple runtime primitive. The plugin can preserve the metadata in normalized config output and explicitly create deterministic anonymous volumes with labels before handing container creation to Apple/container. Named service mount labels should remain metadata because Docker Compose does not apply them to named volume resources.

## Expected behavior

- `container compose config --format json` preserves service long-form `volume.labels`.
- `container compose up`, `create`, and `run` accept service volume labels.
- Anonymous service volume labels are applied when the plugin creates the deterministic anonymous runtime volume.
- Named service mount labels remain metadata; top-level named volume labels continue to drive named volume resource creation.
- `volume.subpath` remains unsupported until Apple/container exposes compatible subpath mount semantics.
