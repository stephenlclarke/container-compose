<!-- markdownlint-disable MD013 -->

# Existing feature request: add container event streaming

Existing upstream issue: [apple/container#484](https://github.com/apple/container/issues/484).

Do not open a duplicate issue unless Apple maintainers ask for a fresh, narrower issue. Use this draft to prepare comments or issue-body follow-up notes that connect the existing request to the `container-compose` compatibility work.

## Feature Or Enhancement Request Details

`container-compose` exposed the `container compose events` command name before released upstream `apple/container` had an event stream. Docker Compose users expect project-scoped event output for container lifecycle changes, and the plugin needs a generic runtime event primitive before it can add Compose service filtering and formatting.

The existing upstream issue asks for an event channel for container stop/start and image pull/remove style notifications. The first slice satisfies the container lifecycle subset without trying to solve every possible future event source.

## Implemented First Slice

- Add a `ContainerEvent` model in `ContainerResource`.
- Expose a streaming `ContainerClient.events()` API through the existing `containerEvent` XPC route.
- Emit lifecycle events for container create, start, stop, pause, unpause, delete, and auto-remove delete paths that are already visible at the API-service layer.
- Preserve enough payload shape for Docker Compose's later JSON fields: event time, resource type, action, resource ID, and stable attributes.
- Add a `container events` CLI surface that streams newline-delimited `ContainerEvent` JSON.
- Keep event payloads generic and runtime-owned: container ID, action/type, timestamp, image/status metadata, and container labels.
- Keep Compose project/service filtering, `--json`, selected services, and Docker Compose output formatting in `container-compose`, not in `apple/container`.

## Docker And Docker Compose Guidance

- Docker Compose docs: [docker compose events](https://docs.docker.com/reference/cli/docker/compose/events/)
- Docker engine events docs: [docker system events](https://docs.docker.com/reference/cli/docker/system/events/)
- Docker Compose command source: [cmd/compose/events.go](https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/cmd/compose/events.go)
- Docker Compose backend source: [pkg/compose/events.go](https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/pkg/compose/events.go)
- Docker Compose event model source: [pkg/api/api.go](https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/pkg/api/api.go)
- Docker Compose issue [docker/compose#13700](https://github.com/docker/compose/issues/13700): open issue noting that Compose currently emits only container events and drops network, volume, and image events.

Docker Compose currently presents project-scoped container events and leaves broader engine object events out of `compose events`. Its implementation filters project events to `container`, skips one-off containers, applies selected-service filtering, strips internal `com.docker.compose.*` attributes, and renders JSON fields `time`, `type`, `service`, `id`, `action`, and `attributes`.

The Apple runtime event primitive is therefore resource-typed and label-aware, but the first `container-compose` mapping should stay container-focused until Docker Compose behavior changes or the project deliberately chooses to exceed it.

## Existing Upstream Context

- [apple/container#484](https://github.com/apple/container/issues/484): open feature request for a container events stream.
- The current Apple review is maintained in
  [APPLE-UPSTREAM-REVIEW.md](../APPLE-UPSTREAM-REVIEW.md); re-check it before
  submitting this slice so a newer overlapping event-stream PR is used as the
  base instead of duplicated.

## Minimal Compose Example

```yaml
name: event-demo

services:
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 3600"]
```

The dependent `container-compose` behavior is tracked separately in `docs/upstream/events/ISSUE-compose-events.md` / `docs/upstream/events/PR-compose-events.md`, with `--since` / `--until` follow-up tracking in `docs/upstream/events/ISSUE-compose-event-time-filters.md` / `docs/upstream/events/PR-compose-event-time-filters.md`:

```sh
container compose events --json api
```

The plugin filters runtime events to containers with the selected Compose project and service labels, then renders Docker Compose compatible event output. Keep that policy out of the Apple runtime PR so [apple/container#484](https://github.com/apple/container/issues/484) remains a generic event-stream primitive.

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] This draft references the existing upstream issue instead of opening a duplicate.
