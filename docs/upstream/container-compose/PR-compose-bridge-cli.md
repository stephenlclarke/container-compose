# Implement the complete Compose Bridge runtime

## Summary

- Implements `bridge convert` for Kubernetes, Helm, and custom transformer images.
- Loads compose-go's public Bridge model and the Swift runtime projection in one parse.
- Loads image metadata, published target ports, config content, and secret content into transformer input.
- Implements stopped-image template extraction for `bridge transformations create`.
- Implements Docker-shaped table, JSON, quiet, `list`, and `ls` transformer discovery.
- Adds destructive-output guards, private input staging, dry-run operations, and live Docker Compose parity coverage.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Compose Bridge converts a resolved Compose project by running one or more labelled transformer images. A complete implementation needs more than the CLI surface: transformer input must include the same runtime-resolved resources as Docker Compose, transformer templates must be recoverable from a stopped image container, and list formats must retain Docker's public shape.

The Docker-shaped behavior stays in `container-compose`. Apple-backed changes remain generic:

- `containerization` decodes Docker image `ExposedPorts` and securely extracts selected archive members.
- `container` projects image labels and exposed ports through `ImageResource.Variant` and exports stopped root filesystems.

## Upstream References

- Docker Compose conversion: <https://github.com/docker/compose/blob/main/pkg/bridge/convert.go>
- Docker Compose transformer lifecycle: <https://github.com/docker/compose/blob/main/pkg/bridge/transformers.go>
- Docker Compose Bridge e2e fixture: <https://github.com/docker/compose/blob/main/pkg/e2e/bridge_test.go>
- Docker temporary conversion cleanup: <https://github.com/docker/compose/issues/13482>
- Docker temporary conversion cleanup fix: <https://github.com/docker/compose/pull/13483>
- Docker native multi-platform transformer fix: <https://github.com/docker/compose-bridge-transformer/pull/22>
- Apple stopped-rootfs export request: <https://github.com/apple/container/issues/1265>
- Apple stopped-rootfs export implementation: <https://github.com/apple/container/pull/1303>

## Commit Tracking

- Image `ExposedPorts` decode: `dcde0cd` in `stephenlclarke/containerization`.
- Image resource metadata projection: `380ff28` in `stephenlclarke/container`.
- Selected-member archive extraction: `5fe7fdc` in `stephenlclarke/containerization`.
- Never-started rootfs export: `dd9ca5e` in `stephenlclarke/container`.
- Materialized-rootfs and corruption guards: `59d49b1`, `9b43e5b`, and integration coverage `145b83f` in `stephenlclarke/container`.
- Apple archive handoff: `docs/upstream/apple-containerization/ISSUE-filtered-archive-extraction.md` and `PR-filtered-archive-extraction.md`.
- Apple export handoff: `docs/upstream/apple-container/ISSUE-export-created-container.md` and `PR-export-created-container.md`.

## Implementation Details

- Preserves compose-go's public YAML field names and structured values instead of re-encoding the Swift runtime projection.
- Preserves each explicit Compose image name while inspecting local image config metadata; build-only services use Docker's `PROJECT-SERVICE` Bridge image name while the local runtime image remains unchanged.
- Adds image-exposed ports and every published target port, including ranges, to service `expose`.
- Embeds local file and environment-backed config and secret content in Bridge input.
- Stages `compose.yaml` in a unique `0700` directory as a `0600` file.
- Treats an empty output path as the current directory without deleting it and rejects root, current, or ancestor output paths before replacement.
- Creates a transformer container without starting it, exports its image snapshot through `ContainerClient.export`, extracts only `templates`, removes the container and temporary archive, and writes the standard transformer Dockerfile.
- Emits Docker-compatible image summary keys for `--format json` and the `TAGS` table header.
- Verifies the running `container-apiserver` revision as well as the CLI revision before runtime work.
- Pins live parity to the immutable indexes used by Docker's fixture and selects amd64 for affected official images whose mislabeled platform binaries are tracked by `docker/compose-bridge-transformer#22`; current untagged and `latest` images stay native.

## Validation

```bash
swift test --disable-automatic-resolution --filter bridge
swift test --disable-automatic-resolution --filter ContainerPackageCompatibility
go test ./...
make docker-compose-bridge-parity
make ci-fast
make cli-smoke-built
make swift-runtime-test
make docker-compose-parity
```

## Compatibility Notes

Transformer images run through the local Apple container runtime and must be available locally or pullable from its configured registry. Docker Desktop deployment integration is outside the CLI contract; generated Kubernetes, Helm, and custom-template artifacts match Docker Compose Bridge behavior.
