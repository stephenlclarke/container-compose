# Pull Request

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change implements Docker Compose v2 `pause` and `unpause` service lifecycle commands for the local fork-backed integration stack.

Previously, `container compose pause` and `container compose unpause` existed only as placeholders that reported missing `apple/container` runtime primitives. The matching local `containerization` and `container` branches now expose the required pause/resume lifecycle APIs, so `container-compose` can route service selection through the existing direct API lifecycle adapter.

References:

- Docker Compose pause: <https://docs.docker.com/reference/cli/docker/compose/pause/>
- Docker Compose unpause: <https://docs.docker.com/reference/cli/docker/compose/unpause/>
- Docker container pause: <https://docs.docker.com/reference/cli/docker/container/pause/>
- Docker container unpause: <https://docs.docker.com/reference/cli/docker/container/unpause/>

## Implementation Details

- Added `pauseContainer(id:)` and `unpauseContainer(id:)` to the lifecycle API and lifecycle manager protocols.
- Added default direct `ContainerClient.pause(id:)` and `ContainerClient.unpause(id:)` operations to `ContainerLifecycleAPIClient`.
- Added `ComposeOrchestrator.pause(project:services:)` and `ComposeOrchestrator.unpause(project:services:)`.
- Changed the plugin `Pause` and `Unpause` commands from unsupported placeholders to async project commands.
- Preserved dry-run behavior by rendering `container pause <id>` and `container unpause <id>`.
- Updated compatibility documentation and PLAN tracking to describe fork-backed support and upstream gating.
- Updated `Package.resolved` to pin `containerization` to the same fork revision used by the matching `container` branch.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --filter ComposeOrchestratorTests/pauseAndUnpauseUseDirectRuntimeAPI
swift test --filter ComposeOrchestratorTests/pauseAndUnpauseDryRunEmitRuntimeCommands
swift test --filter ComposeOrchestratorTests/lifecycleManagerMapsComposeLifecycleToDirectAPIClient
swift test --filter ComposeOrchestratorTests/lifecycleAPIClientForwardsConfiguredOperations
swift build --product compose
make lint
make check-licenses
git diff --check
```

## Dependency Notes

This support depends on fork-backed runtime functionality until matching upstream changes are accepted:

- `stephenlclarke/containerization@integration/blkio-runtime` commit `e172174`
- `stephenlclarke/container@logs-integration-chris` commit `61a11f4`

Branches pinned to released upstream `apple/container` should continue to classify `pause` and `unpause` as runtime-gated.

## Remaining Risks

- End-to-end validation requires a local `container` installation built from the matching fork branches.
- Upstream API names or pause semantics may change during `apple/container` review; the lifecycle adapter should absorb those changes without spreading churn across the orchestrator.
