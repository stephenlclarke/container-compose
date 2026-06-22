<!-- markdownlint-disable MD013 -->

# feat(events): stream container lifecycle events

Related issue: [apple/container#484](https://github.com/apple/container/issues/484).

## Summary

- Add a `ContainerEvent` resource model and API-service event broadcaster.
- Expose `ContainerClient.events()` through the existing container event XPC route.
- Emit JSON Lines lifecycle events from API-service create/start/stop/pause/unpause/delete paths and add a thin `container events` CLI.

## Type Of Change

- [x] New feature
- [ ] Bug fix
- [ ] Breaking change
- [x] Documentation update

## Motivation And Context

Docker-compatible clients need an event stream to observe lifecycle changes without polling. `container-compose` needs this runtime primitive before it can implement `container compose events --json [SERVICE...]` while keeping Compose filtering and formatting in the plugin.

The existing upstream feature request is [apple/container#484](https://github.com/apple/container/issues/484). A live check on 2026-06-22 did not find an existing event-stream PR in `apple/container`; the first implementation slice stays in `apple/container` because all included lifecycle transitions are already visible at the API-service layer.

Docker guidance checked for this slice:

- Docker Compose docs: [docker compose events](https://docs.docker.com/reference/cli/docker/compose/events/)
- Docker engine events docs: [docker system events](https://docs.docker.com/reference/cli/docker/system/events/)
- Docker Compose source: `cmd/compose/events.go`, `pkg/compose/events.go`, and `pkg/api/api.go` at [docker/compose commit 9b55a6e](https://github.com/docker/compose/tree/9b55a6e9c1016fd3c31859b7e09260378d45a783)
- Docker Compose issue [docker/compose#13700](https://github.com/docker/compose/issues/13700) documents that current Compose emits only container events, even though the Docker engine can return network, volume, and image events.

## Commit Tracking

- Container code commits to squash:
  - `b71e4bb323e3 feat(events): stream container lifecycle events`
  - `0da7890b2632 fix(events): avoid blocking slow event subscribers`
- Lower runtime code commit: none; this slice does not require `apple/containerization`.
- Compose mapping code commit: `113be38063ea feat(events): map compose events` in `stephenlclarke/container-compose`, tracked in `docs/upstream/events/PR-compose-events.md`, not part of this Apple PR.
- Follow-up event time-filter code commit: `d0977b5a99ec7dfd4fdc9a3b5e50b36869451270 feat(events): add event time filters`, tracked in `docs/upstream/events/PR-container-event-time-filters.md`, not part of this first Apple event-stream PR.

Use these commits as the code candidates for one upstream `apple/container` PR.

## Implementation Details

- Defines `ContainerEvent` in `ContainerResource` with `time`, `type`, `id`, `action`, and `attributes`.
- Adds an API-service `ContainerEventBroadcaster` that writes newline-delimited, ISO 8601 encoded `ContainerEvent` JSON records to subscribers.
- Reuses the existing `XPCKeys.containerEvent` / `XPCRoute.containerEvent` names for the stream boundary.
- Adds `ContainerClient.events()` returning a `FileHandle` for the JSON Lines stream.
- Registers the event route in `container-apiserver`.
- Emits events after successful create, init-process start, pause, unpause, stopped-container transition, forced running-container delete, normal delete, and auto-remove delete paths.
- Includes container labels in event attributes so later clients can filter by Compose project/service labels without adding Compose policy here.
- Adds `image` and `status` attributes for stable, direct runtime context.
- Adds `container events`, which streams the raw JSON Lines event stream.

## Out Of Scope

- `container compose events` implementation.
- Compose project/service filtering.
- Docker Compose output formatting and `--json` option handling.
- Stripping `com.docker.compose.*` attributes; that is a Compose plugin concern.
- Image pull/remove, network, and volume events.
- Health status change events.
- Restart policy changes beyond observing the existing stop/start transitions that the API service already performs.
- `apple/containerization` changes.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
/usr/bin/swift test --filter 'ContainerEventTests|ContainerEventBroadcasterTests'
```

Planned pre-PR validation:

```sh
/usr/bin/swift build --product container --product container-apiserver
git diff --check
markdownlint ISSUE-container-events-stream.md PR-container-events-stream.md
```

## Compatibility Notes

Released `container-compose` branches must continue treating `events` as runtime-gated until an accepted `apple/container` event stream is available. The local fork-backed `container-compose` branch now has a separate plugin slice for project label filtering, selected service filtering, JSON output, and Docker Compose compatible rendering; do not fold that Compose policy into this Apple runtime PR.

## Remaining Risks

- The stream currently uses an in-memory subscriber list and does not replay events from before subscription. Disconnected or slow subscribers are pruned when the non-blocking write side cannot accept the next record.
- The follow-up `PR-container-event-time-filters.md` adds bounded in-memory replay and `--since` / `--until` support. Keep it separate when constructing this first event-stream PR.
- Event timestamps are observed at the API-service boundary rather than at a lower runtime source. That is intentional for this first slice because the included lifecycle transitions are already serialized through the API service.
- The CLI intentionally streams JSON Lines only. Human-readable formatting can be reviewed separately if maintainers want a richer `container events` presentation.
