<!-- markdownlint-disable MD013 -->

# Compose compatibility gap: project-scoped events

## Compose Surface

`docker compose events --json [SERVICE...]`

## Docker Compose v2 Behavior

Docker Compose V2 exposes a real-time project event stream:

```sh
docker compose events --json api
```

For the current Docker Compose implementation checked at `docker/compose@9b55a6e9c1016fd3c31859b7e09260378d45a783`, the command:

- subscribes to Docker engine events using the Compose project filter;
- keeps only `container` events;
- skips one-off `docker compose run` containers;
- applies selected service arguments;
- forwards `--since` and `--until` to the Docker engine event stream;
- strips internal `com.docker.compose.*` attributes;
- renders JSON fields `time`, `type`, `service`, `id`, `action`, and `attributes`.

References:

- Docker Compose events docs: <https://docs.docker.com/reference/cli/docker/compose/events/>
- Docker engine events docs: <https://docs.docker.com/reference/cli/docker/system/events/>
- Docker Compose command source: <https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/cmd/compose/events.go>
- Docker Compose backend source: <https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/pkg/compose/events.go>
- Docker Compose event model: <https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/pkg/api/api.go>
- Docker Compose issue [docker/compose#13700](https://github.com/docker/compose/issues/13700), which confirms current Compose behavior is container-event scoped even though broader Docker engine object events exist.

## Existing Source And Stacking Decision

The generic runtime dependency is the existing upstream feature request [apple/container#484](https://github.com/apple/container/issues/484). A live check on 2026-06-22 found no open `apple/container` PR that implements an event stream, and no `apple/containerization` issue or PR needed for the first lifecycle-event source.

This Compose slice stacks on the local `apple/container` PR-shaped runtime primitive documented in:

- `docs/upstream/events/ISSUE-container-events-stream.md`
- `docs/upstream/events/PR-container-events-stream.md`

That runtime slice adds `ContainerEvent`, `ContainerClient.events()`, API-service lifecycle event emission, non-blocking subscribers, and a raw `container events` JSON Lines CLI. It intentionally does not include Compose project/service filtering, selected-service filtering, one-off suppression, or Docker Compose output formatting.

Follow-up event slices are tracked separately in:

- `docs/upstream/events/ISSUE-container-event-time-filters.md`
- `docs/upstream/events/PR-container-event-time-filters.md`
- `docs/upstream/events/ISSUE-compose-event-time-filters.md`
- `docs/upstream/events/PR-compose-event-time-filters.md`
- `docs/upstream/events/ISSUE-compose-events-text-format.md`
- `docs/upstream/events/PR-compose-events-text-format.md`

This repository did not choose Docker Compose source code as a base because it is Go code tied to the Docker engine event API, Docker actor attributes, and `com.docker.compose.*` label keys. The usable source is the behavioral contract and filtering order. `container-compose` implements the equivalent policy against this plugin's Apple-specific labels, `com.apple.container.compose.*`, while preserving the same public JSON shape.

## Current container-compose Behavior

Before this slice, `container compose events` existed only as a placeholder that returned an unsupported-feature error.

With this slice on the local fork-backed integration stack:

- `container compose events --json [SERVICE...]` opens `ContainerClient.events()`.
- Runtime events are filtered to `type == "container"`.
- Events are scoped to the current Compose project label.
- One-off containers created through `compose run` are skipped.
- Selected services are applied before rendering.
- Compose-private attributes using `com.apple.container.compose.*` or `com.docker.compose.*` are stripped from the public JSON payload.
- The output is newline-delimited JSON with `time`, `type`, `service`, `id`, `action`, and `attributes`.
- `--since` and `--until` are supported on the local integration stack through the separate runtime and Compose time-filter slices.
- Non-JSON event formatting was out of scope for this first plugin slice and is now tracked by the follow-up text-format slice.

## Likely Owner

`container-compose` owns project/service filtering, selected-service arguments, one-off suppression, Compose-private attribute stripping, and Docker Compose compatible output.

`apple/container` owns the generic event stream primitive. Released upstream branches must keep treating `events` as runtime-gated until an accepted equivalent of the local `ContainerClient.events()` primitive exists.

`apple/containerization` is not required for this slice because the first event source is API-service lifecycle transitions already observed in `apple/container`.

## Local Docker Compose Parity Evidence

This repository now includes an optional, non-CI Docker Compose V2 parity check:

```sh
make docker-compose-events-parity
```

The script requires a local Docker daemon and Docker Compose V2. It is intentionally not wired into CI so Apple-facing repositories do not depend on Docker. The check validates the Docker behavior this slice mirrors: container-scoped JSON events, selected-service filtering, internal Compose label stripping, one-off container suppression, and, after follow-up slices, `--since` / `--until` replay-window shape plus default text event shape.

## Minimal Example

```yaml
name: event-demo

services:
  api:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 3600"]
```

Expected fork-backed behavior:

```sh
container compose events --json api
```

Example event shape:

```json
{"action":"start","attributes":{"image":"alpine:3.20","status":"running"},"id":"event-demo-api-1","service":"api","time":"2026-06-22T10:00:00Z","type":"container"}
```

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `DOCKER-COMPOSE-PARITY.md`.
- [x] I checked `STATUS.md`.
- [x] I checked current Apple issues and PRs before selecting this slice.
- [x] I recorded whether matching upstream items were used as a base, dependency, or behavioral reference.
