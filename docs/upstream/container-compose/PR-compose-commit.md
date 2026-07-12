# Support `compose commit` for service containers

## Summary

This change fills the Compose-owned part of Docker Compose v2 `commit` parity:

- Replaces the unsupported `commit` placeholder with a real project command.
- Parses `--author`, repeated `--change`, `--index`, `--message`, and `--pause` plus Docker short forms handled by the argument rewriter.
- Exports stopped service container filesystems through the existing runtime export adapter.
- Builds a single-layer OCI image archive with Docker-compatible image config metadata.
- Seeds committed image config from base image metadata before applying Compose service overrides and `--change`.
- Loads the generated image archive through the direct image adapter.
- Keeps running-container commit, including `--pause=false`, partial and blocked on Apple live export/snapshot support.

## Rationale

Docker Compose implements `commit` by resolving a service container and calling Docker Engine `ContainerCommit`. Apple does not yet expose a generic live snapshot/freeze primitive, and Apple review on [apple/container#1262](https://github.com/apple/container/pull/1262) points away from a broad Docker-shaped commit endpoint.

The stopped-container path does not need new Apple APIs: `container-compose` can reuse export and image load primitives, build a standards-shaped OCI archive, and keep all Docker Compose option parsing in the Compose layer. Running-container commit remains explicitly gated on [apple/container#1400](https://github.com/apple/container/issues/1400) and [apple/containerization#660](https://github.com/apple/containerization/issues/660), including Docker Compose's explicit `--pause=false` mode, because the current Apple export primitive rejects running containers.

## Upstream References

- Docker Compose `commit` command source: `docker/compose` `cmd/compose/commit.go` and `pkg/compose/commit.go`.
- [apple/container#1399](https://github.com/apple/container/issues/1399): tracks an upstream `container commit` command.
- [apple/container#1400](https://github.com/apple/container/issues/1400): tracks live container export/commit consistency.
- [apple/container#1262](https://github.com/apple/container/pull/1262): closed PR with maintainer feedback to avoid a broad endpoint and reuse export/load behavior.
- [apple/containerization#660](https://github.com/apple/containerization/issues/660): lower-runtime freeze/thaw/snapshot tracking.

## Implementation Details

- Added `ComposeCommitOptions` and a `ComposeOrchestrator.commit(project:serviceName:options:)` path.
- Added `ComposeCommitImageArchive` to write an OCI layout tar from an exported rootfs archive.
- Added image archive load support to `ContainerImageAPIClienting`, `ContainerImageManaging`, and the live image adapter.
- Extended compact image metadata with config fields needed to preserve Docker commit image config parity.
- Implemented stopped-container runtime validation through `ContainerDiscoveryManaging.getContainer(id:)`.
- Rejects running-container commit before export with Apple live export/snapshot blockers.
- Added dry-run output for the export, archive creation, and image load steps.
- Added `commit` argument rewriting for Docker short forms and optional boolean `--pause=false`.
- Marked the command partial in help/status while keeping all documented options green.

## Repository Scope

- The Compose service selection, Docker Compose CLI parsing, image config shaping, and OCI archive creation stay in `stephenlclarke/container-compose`.
- No `apple/container` or `apple/containerization` code change is required for the current supported service commit behavior.

## Testing

Focused validation:

```sh
swift test --filter ComposeOrchestratorTests/commit
swift test --filter ComposeArgumentRewriterTests
swift test --filter ComposeCLIHelpTests
```

Before release promotion:

```sh
make ci
make docker-compose-parity
git diff --check
```

## Compatibility Notes

- Stopped service containers can be committed and loaded as images.
- `--pause=false` parses for Docker Compose CLI compatibility, but running service containers still wait for Apple live export/snapshot support.
- Running service containers with default `--pause=true` fail before export/load because a consistent paused live snapshot requires Apple upstream runtime support.
- Docker-specific image config changes stay in `container-compose`.

## Remaining Risks

- The OCI archive writer intentionally supports the Docker `--change` instruction set accepted by Docker Engine commit; future Docker Compose changes may add flags that need a Compose-layer update.
- Running-container commit should be revisited after Apple resolves the live export/snapshot/freeze work in [apple/container#1400](https://github.com/apple/container/issues/1400) and [apple/containerization#660](https://github.com/apple/containerization/issues/660).

## Checklist

- [x] Added or updated tests
- [x] Added or updated documentation
- [x] Recorded upstream issue and PR references
- [x] Kept Docker Compose policy in the Compose layer
- [x] Avoided pushing changes to Apple remotes
