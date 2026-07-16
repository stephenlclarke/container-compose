# Support `compose commit` for service containers

## Summary

This change fills the Compose-owned part of Docker Compose v2 `commit` parity:

- Replaces the unsupported `commit` placeholder with a real project command.
- Parses `--author`, repeated `--change`, `--index`, `--message`, and `--pause` plus Docker short forms handled by the argument rewriter.
- Exports stopped service container filesystems through the existing runtime export adapter and requests a filesystem-consistent live snapshot for running containers with default `--pause=true`.
- Builds a single-layer OCI image archive with Docker-compatible image config metadata.
- Seeds committed image config from base image metadata before applying Compose service overrides and `--change`.
- Preserves Docker `Healthcheck` metadata and resolves Compose healthcheck overrides into the committed image config.
- Matches Docker Compose's `--index` default by treating omitted `--index` and `--index=0` as unset service-container selection.
- Loads the generated image archive through the direct image adapter.
- Keeps `--pause=false` partial because the runtime cannot safely export a writable filesystem without the brief freeze used by the default live snapshot.

## Rationale

Docker Compose implements `commit` by resolving a service container and calling Docker Engine `ContainerCommit`. Apple has merged the lower-runtime freeze/thaw filesystem operation API in [apple/containerization#685](https://github.com/apple/containerization/pull/685). The companion fork handoff adds a generic `container export --live` snapshot primitive based on [apple/container#1630](https://github.com/apple/container/pull/1630).

The stopped-container path reuses export and image-load primitives, builds a standards-shaped OCI archive, and keeps all Docker Compose option parsing in the Compose layer. The running default path requests the generic live snapshot. Explicit `--pause=false` remains gated on a future safe no-freeze writable-filesystem snapshot; the Docker-shaped upstream `container commit` draft in [apple/container#1762](https://github.com/apple/container/pull/1762) is intentionally not used.

## Upstream References

- Docker Compose `commit` command source: `docker/compose` `cmd/compose/commit.go` and `pkg/compose/commit.go`.
- [apple/container#1399](https://github.com/apple/container/issues/1399): tracks an upstream `container commit` command.
- [apple/container#1400](https://github.com/apple/container/issues/1400): tracks live container export/commit consistency.
- [apple/container#1630](https://github.com/apple/container/pull/1630): active Apple live-export implementation.
- [apple/container#1762](https://github.com/apple/container/pull/1762): draft Apple `container commit` command.
- [apple/container#1262](https://github.com/apple/container/pull/1262): closed PR with maintainer feedback to avoid a broad endpoint and reuse export/load behavior.
- [apple/containerization#685](https://github.com/apple/containerization/pull/685): merged lower-runtime freeze/thaw filesystem operations.

## Implementation Details

- Added `ComposeCommitOptions` and a `ComposeOrchestrator.commit(project:serviceName:options:)` path.
- Added `ComposeCommitImageArchive` to write an OCI layout tar from an exported rootfs archive.
- Added image archive load support to `ContainerImageAPIClienting`, `ContainerImageManaging`, and the live image adapter.
- Extended compact image metadata with config fields, including Docker `Healthcheck`, needed to preserve Docker commit image config parity.
- Implemented stopped-container export and running-container live-snapshot selection through `ContainerDiscoveryManaging.getContainer(id:)`.
- Resolves omitted `--index` and `--index=0` through Docker Compose-compatible default service-container selection.
- Uses the live-export primitive for running containers with default `--pause=true`, and rejects `--pause=false` before export with the exact platform limitation.
- Added dry-run output for the export, archive creation, and image load steps.
- Added `commit` argument rewriting for Docker short forms and optional boolean `--pause=false`.
- Marked the command and `--pause` option partial in colour-coded help/status, with the precise supported default and residual `--pause=false` limitation.

## Repository Scope

- The Compose service selection, Docker Compose CLI parsing, image config shaping, and OCI archive creation stay in `stephenlclarke/container-compose`.
- The generic `apple/container`-shaped primitive is documented in [PR-live-export-snapshot.md](../apple-container/PR-live-export-snapshot.md) and implemented in the Stephen fork. No Docker-shaped `container commit` endpoint is needed.

## Testing

Focused validation:

```sh
swift test --filter ComposeOrchestratorTests/commit
swift test --filter ComposeArgumentRewriterTests
swift test --filter ComposeCLIHelpTests
make docker-compose-commit-parity
```

Before release promotion:

```sh
make ci
make docker-compose-parity
git diff --check
```

## Compatibility Notes

- Stopped service containers can be committed and loaded as images.
- `--pause=false` parses for Docker Compose CLI compatibility, but remains unavailable for running service containers because the backend cannot safely snapshot a writable filesystem without a freeze.
- Running service containers with default `--pause=true` export through a brief filesystem-consistent live snapshot before archive creation and load. This is not a full Docker process pause.
- Docker-specific image config changes stay in `container-compose`.

## Remaining Risks

- The OCI archive writer intentionally supports the Docker `--change` instruction set accepted by Docker Engine commit; future Docker Compose changes may add flags that need a Compose-layer update.
- `--pause=false` should be revisited only after Apple offers a safe no-freeze snapshot; the generic live-export handoff is tracked in [PR-live-export-snapshot.md](../apple-container/PR-live-export-snapshot.md).

## Checklist

- [x] Added or updated tests
- [x] Added or updated documentation
- [x] Recorded upstream issue and PR references
- [x] Kept Docker Compose policy in the Compose layer
- [x] Avoided pushing changes to Apple remotes
