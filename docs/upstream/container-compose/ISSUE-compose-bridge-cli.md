# Compose compatibility gap: Bridge CLI runtime

## Compose Surface

```bash
docker compose bridge convert [OPTIONS]
docker compose bridge transformations create [OPTIONS] PATH
docker compose bridge transformations list [OPTIONS]
docker compose bridge transformations ls [OPTIONS]
```

## Docker Compose v2 Behavior

Docker Compose Bridge converts a resolved Compose model into another model by running transformer images. Docker's CLI documents `bridge convert` with `--output`, `--templates`, and `--transformation`, and documents transformation management commands for `create`, `list`, and the `ls` alias.

Docker's implementation enriches the Compose model before conversion by inspecting service images, pulling missing images, setting resolved image references, and adding image-declared exposed ports to the service model. It identifies transformer images with `com.docker.compose.bridge=transformation`.

References:

- <https://docs.docker.com/reference/cli/docker/compose/bridge/convert/>
- <https://docs.docker.com/reference/cli/docker/compose/bridge/transformations/>
- <https://docs.docker.com/reference/cli/docker/compose/bridge/transformations/create/>
- <https://docs.docker.com/reference/cli/docker/compose/bridge/transformations/list/>
- <https://github.com/docker/compose/blob/main/pkg/bridge/convert.go>
- <https://github.com/docker/compose/blob/main/pkg/bridge/transformers.go>

## Current container-compose Behavior

`container-compose` now implements the Bridge command surface on the fork-backed runtime lane. The plugin owns command parsing, dry-run text, Compose model enrichment, transformer container execution, list output formatting, and template extraction. The Apple-backed repos only provide generic image config metadata needed by this runtime.

## Acceptance Criteria

- `container compose bridge` and nested Bridge help pages show supported status.
- `bridge convert` loads the selected project, enriches service images with local image metadata, writes Bridge input YAML, and runs each transformer image with `/in`, `/out`, optional `/templates`, `LICENSE_AGREEMENT=true`, and the current user id.
- Missing transformer and service images are pulled before use.
- `bridge transformations list` supports table, JSON, quiet, and `ls` alias output.
- `bridge transformations create` copies `/templates` from a transformer image into the destination and writes a rebuildable Dockerfile.
- Root project globals are accepted in Docker Compose-compatible positions for `bridge convert`; `--dry-run` is accepted for Bridge management commands.
- `STATUS.md`, CLI help color status, and Makefile smoke coverage report the Bridge surface as supported.
