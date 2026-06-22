# Apple Open Issue And PR Snapshot

Snapshot date: 2026-06-22.

This snapshot records the upstream state checked before selecting the next slab after the PID-only process-listing / `top` slice.

## Query Scope

The following complete open sets were queried with `gh`:

```sh
gh issue list --repo apple/container --state open --limit 1000 --json number,title,url,labels,updatedAt,createdAt,author
gh pr list --repo apple/container --state open --limit 1000 --json number,title,url,labels,updatedAt,createdAt,author,headRefName,baseRefName,isDraft
gh issue list --repo apple/containerization --state open --limit 1000 --json number,title,url,labels,updatedAt,createdAt,author
gh pr list --repo apple/containerization --state open --limit 1000 --json number,title,url,labels,updatedAt,createdAt,author,headRefName,baseRefName,isDraft
```

| Repository | Open issues | Open PRs |
| --- | ---: | ---: |
| `apple/container` | 252 | 109 |
| `apple/containerization` | 29 | 21 |

## Event Stream Findings

| Repository | Match | Status | Notes |
| --- | --- | --- | --- |
| `apple/container` | [apple/container#484](https://github.com/apple/container/issues/484), `[Request]: Add container events stream` | Open issue | Requests an event channel for container stop/start and image pull/remove style notifications. No comments were present at query time. |
| `apple/container` | Open PR search for event/event-stream/events | No matching open PR | The next event slice should reference #484 rather than open an unrelated duplicate issue. |
| `apple/containerization` | Open issue and PR search for event/event-stream/events | No matching open issue or PR | First event slice should start in `apple/container` unless implementation proves lower-runtime state is required. |
| `apple/container` | Open issue and PR search for event replay / `since` / `until` | No matching open issue or PR | The event time-filter slice should stack on #484 and the event-stream primitive rather than open a duplicate top-level event issue. |
| `apple/containerization` | Open issue and PR search for event replay / `since` / `until` | No matching open issue or PR | No lower-runtime dependency was identified for bounded API-service replay and filtering. |

## Adjacent Runtime-Data Items

- [apple/container#378](https://github.com/apple/container/issues/378): attach terminal to a running container. Adjacent for interactive streams, but not an event-stream implementation.
- [apple/container#1747](https://github.com/apple/container/issues/1747) and [apple/container#1778](https://github.com/apple/container/pull/1778): signal forwarding. Adjacent for process-control events, but not a replacement for `container events`.
- [apple/container#1258](https://github.com/apple/container/pull/1258): restart policy. Event output should eventually observe restarts, but the event primitive should not bundle restart policy changes.
- [apple/container#1504](https://github.com/apple/container/pull/1504): health status. Health status changes may become event payloads later, but the first event slice can start with lifecycle events.
- [apple/container#1595](https://github.com/apple/container/pull/1595) and [apple/containerization#739](https://github.com/apple/containerization/pull/739): blkio resource controls. Already used by the completed `blkio_config` mapping; not a next-slab blocker.

## Selection And Outcome

The selected slab was runtime event streaming for `container compose events`. The first slice is now implemented as a single `apple/container` PR-shaped runtime/API/CLI primitive that references [apple/container#484](https://github.com/apple/container/issues/484). The constructible Apple code commits are `b71e4bb323e3` (`feat(events): stream container lifecycle events`) and `0da7890b2632` (`fix(events): avoid blocking slow event subscribers`) in `stephenlclarke/container`, with local handoff docs in `48b763c` and `24dcfbc`.

The second slice is the `container-compose` `events --json [SERVICE...]` mapping. It is intentionally not part of the Apple runtime PR: the plugin slice consumes `ContainerClient.events()` while keeping Compose project/service filtering, selected service arguments, one-off suppression, private label stripping, and Docker Compose JSON rendering policy in this repository. Its constructible code commit is `113be38063ea` (`feat(events): map compose events`) in `stephenlclarke/container-compose`; handoff drafts are `docs/upstream/events/ISSUE-compose-events.md` and `docs/upstream/events/PR-compose-events.md`.

The third slice is the `apple/container` event replay/time-filter primitive. It stacks on [apple/container#484](https://github.com/apple/container/issues/484) and the event-stream PR, adds `ContainerEventOptions`, bounded in-memory event replay, and `container events --since/--until`, and remains independent of `apple/containerization`. Its constructible code commit is `d0977b5a99ec7dfd4fdc9a3b5e50b36869451270` (`feat(events): add event time filters`) in `stephenlclarke/container`; handoff drafts are `docs/upstream/events/ISSUE-container-event-time-filters.md` and `docs/upstream/events/PR-container-event-time-filters.md`, mirrored under `docs/upstream/apple-container/`.

The fourth slice is the `container-compose` `events --json --since/--until [SERVICE...]` mapping. It consumes `ContainerEventOptions` while keeping Compose parsing, project/service filtering, one-off suppression, private label stripping, and JSON output policy in this repository. Its constructible code commit is `3a3387d7dbea301eec3a7f1fcc3f954dec80276c` (`feat(events): support compose event time filters`) in `stephenlclarke/container-compose`; handoff drafts are `docs/upstream/events/ISSUE-compose-event-time-filters.md` and `docs/upstream/events/PR-compose-event-time-filters.md`.

## Docker And Docker Compose Guidance

- Docker CLI reference for `docker compose events`: [Docker Compose events docs](https://docs.docker.com/reference/cli/docker/compose/events/)
- Docker CLI reference for `docker system events`: [Docker engine events docs](https://docs.docker.com/reference/cli/docker/system/events/)
- Docker Compose command implementation: [cmd/compose/events.go](https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/cmd/compose/events.go)
- Docker Compose backend implementation: [pkg/compose/events.go](https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/pkg/compose/events.go)
- Docker Compose event model: [pkg/api/api.go](https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/pkg/api/api.go)
- Docker Compose issue [docker/compose#13700](https://github.com/docker/compose/issues/13700): open issue noting that Compose currently emits only container events and drops network, volume, and image events.

Key guidance for this slice:

- `docker compose events` streams project container events, supports service arguments, and exposes `--json`, `--since`, and `--until`.
- Docker engine events cover more object types and actions than Compose currently emits. The first `apple/container` slice should choose a generic event payload while letting the later Compose slice filter down to Compose-compatible container events.
- Docker Compose's source filters project events to container events, skips one-off containers, applies selected-service filtering, strips `com.docker.compose.*` attributes, and formats JSON as `time`, `type`, `service`, `id`, `action`, and `attributes`.
- The local `container-compose` slices mirror that current Docker Compose behavior for `events --json [SERVICE...]` and `events --json --since/--until [SERVICE...]`, and keep the optional Docker parity check outside CI so Apple-facing repositories do not depend on Docker.
- The open Docker Compose issue about dropped non-container events argues for making the Apple runtime event payload generic enough for later network, volume, and image events, even while the first Compose mapping stays container-focused.
