# Pull Request

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change adds pause/unpause lifecycle controls to `container`.

Docker exposes this through `docker container pause` and `docker container unpause`, and Docker Compose exposes the same service lifecycle surface through `docker compose pause` and `docker compose unpause`. `container-compose` needs a direct `apple/container` primitive for these commands so it does not shell out to unsupported behavior or silently skip lifecycle requests.

Following JLogan's guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), pause/unpause remains an Apple-native resource-management primitive. Compose service selection and Docker Compose command semantics stay in `container-compose`.

The change builds on the `stephenlclarke/containerization` commit that adds the missing public `LinuxContainer.pause()` and `LinuxContainer.resume()` bridge over the already-present VM pause/resume hooks.

References:

- Docker container pause: <https://docs.docker.com/reference/cli/docker/container/pause/>
- Docker container unpause: <https://docs.docker.com/reference/cli/docker/container/unpause/>
- Docker Compose pause: <https://docs.docker.com/reference/cli/docker/compose/pause/>
- Docker Compose unpause: <https://docs.docker.com/reference/cli/docker/compose/unpause/>

## Commit Tracking

- Container code commit: `61a11f4` in `stephenlclarke/container` (`feat(runtime): add container pause controls`).
- Lower runtime dependency commit: `e172174` in `stephenlclarke/containerization` (`feat(runtime): add linux container pause controls`).
- Compose mapping code commit is tracked in `docs/upstream/container-compose/PR-compose-pause-unpause.md`, not part of this Apple PR.

## Implementation Details

- Added `RuntimeStatus.paused` so paused containers can be listed, inspected, and filtered.
- Added `RuntimeRoutes.pause` and `RuntimeRoutes.resume`.
- Added `RuntimeClient.pause()` and `RuntimeClient.resume()`.
- Added runtime Linux handlers that transition `.running -> .paused` and `.paused -> .running`.
- Added `XPCRoute.containerPause` and `XPCRoute.containerUnpause`.
- Added `ContainerClient.pause(id:)` and `ContainerClient.unpause(id:)`.
- Added API-server harness and service methods for pause/unpause.
- Pausing stops the health-check monitor while the workload is frozen.
- Unpausing restarts health checks as `.starting` when the container has a configured healthcheck.
- `container stop` now rejects paused containers with an explicit unpause-first error.
- `container start` now rejects paused containers with an explicit `container unpause` hint.
- Added `container pause` and `container unpause` CLI commands.
- Updated command reference and tutorial help text.
- Updated the SwiftPM pin to `stephenlclarke/containerization` revision `e172174`, which contains the lower-level runtime bridge.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --filter ContainerLifecycleCommandTests
swift test --filter ContainerStatusTests
swift build --product container --product container-apiserver --product container-runtime-linux
```

Broader validation:

```bash
make fmt
git diff --check
```

## Dependency Notes

The Apple review delta depends on the lower-level pause/resume `LinuxContainer` bridge in `stephenlclarke/containerization` while that primitive is unavailable from upstream `apple/containerization`.

If that runtime bridge lands upstream, the package pin should move back to `apple/containerization` at the accepted release or revision before opening an upstream `apple/container` PR.

## Remaining Risks

- The runtime implementation pauses the VM-backed sandbox. That matches the current one-container-per-sandbox runtime model, but future shared-sandbox designs may need a narrower cgroup/process-freezer primitive.
- Live end-to-end validation requires a running local `container` installation with the matching runtime plugin and should be performed before promoting an upstream PR out of draft.
