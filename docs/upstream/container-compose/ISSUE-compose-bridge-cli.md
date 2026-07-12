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

Docker's implementation enriches the Compose model before conversion by inspecting service images, pulling missing images, loading config and secret content, and combining image-declared and published target ports in the service model. It identifies transformer images with `com.docker.compose.bridge=transformation`.

References:

- <https://docs.docker.com/reference/cli/docker/compose/bridge/convert/>
- <https://docs.docker.com/reference/cli/docker/compose/bridge/transformations/>
- <https://docs.docker.com/reference/cli/docker/compose/bridge/transformations/create/>
- <https://docs.docker.com/reference/cli/docker/compose/bridge/transformations/list/>
- <https://github.com/docker/compose/blob/main/pkg/bridge/convert.go>
- <https://github.com/docker/compose/blob/main/pkg/bridge/transformers.go>
- <https://github.com/docker/compose-bridge-transformer/pull/22>

## Current container-compose Behavior

`container-compose` implements the complete Bridge command surface on the fork-backed runtime lane. The plugin owns command parsing, dry-run text, one-pass compose-go public model loading, model enrichment, transformer container execution, Docker-shaped list output, and template selection. Apple-backed layers provide generic image metadata, never-started rootfs export, and secure filtered archive extraction.

## Acceptance Criteria

- `container compose bridge` and nested Bridge help pages show supported status.
- `bridge convert` loads the runtime projection and compose-go public model in one pass, enriches service images with local image metadata, writes Bridge input YAML, and runs each transformer image with `/in`, `/out`, optional `/templates`, `LICENSE_AGREEMENT=true`, and the current user id.
- Missing transformer and service images are pulled before use.
- `bridge transformations list` supports Docker-shaped table, JSON, quiet, and `ls` alias output.
- `bridge transformations create` exports a stopped transformer rootfs, securely extracts only `/templates`, and writes a rebuildable Dockerfile.
- Root project globals are accepted in Docker Compose-compatible positions for `bridge convert`; `--dry-run` is accepted for Bridge management commands.
- `STATUS.md`, CLI help color status, and Makefile smoke coverage report the Bridge surface as supported.
- Live Kubernetes, Helm, list, alias, and transformer-creation behavior matches Docker Compose's maintained Bridge e2e fixture.
- Runtime compatibility rejects a stale `container-apiserver` before Bridge calls a newer API contract when `container system version` reports the API-server component row.
- Parity pins the immutable transformer indexes used by Docker's maintained fixture. On Apple silicon, versioned or digest-pinned official images affected by `docker/compose-bridge-transformer#22` select their amd64 variant because those indexes advertise non-native binaries; current untagged and `latest` images stay native.
