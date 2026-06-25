<!-- markdownlint-disable MD013 -->

# Compose compatibility gap: event time filters

## Compose Surface

`docker compose events --json --since VALUE --until VALUE [SERVICE...]`

## Docker Compose V2 Behavior

Docker Compose V2 exposes `--since` and `--until` on `docker compose events` and forwards those values to the Docker engine event stream:

```sh
docker compose events --json --since 2026-06-22T10:00:00Z --until 2026-06-22T10:05:00Z api
```

For `docker/compose@9b55a6e9c1016fd3c31859b7e09260378d45a783`, the command layer stores the raw `since` / `until` strings in `api.EventsOptions`, and the backend passes them to `client.EventsListOptions`.

References:

- Docker Compose events docs: <https://docs.docker.com/reference/cli/docker/compose/events/>
- Docker Compose command source: <https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/cmd/compose/events.go>
- Docker Compose backend source: <https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/pkg/compose/events.go>
- Docker engine events docs: <https://docs.docker.com/reference/cli/docker/system/events/>

## Existing Source And Stacking Decision

This Compose slice stacks on the local Apple runtime time-filter primitive:

- `docs/upstream/events/ISSUE-container-event-time-filters.md`
- `docs/upstream/events/PR-container-event-time-filters.md`
- `docs/upstream/apple-container/ISSUE-container-event-time-filters.md`
- `docs/upstream/apple-container/PR-container-event-time-filters.md`

It also depends on the first event-stream slice:

- `docs/upstream/events/ISSUE-container-events-stream.md`
- `docs/upstream/events/PR-container-events-stream.md`

A live GitHub check on 2026-06-22 found no open Apple issue or PR specifically covering event replay, `--since`, or `--until`. [apple/container#484](https://github.com/apple/container/issues/484) remains the correct upstream event-stream anchor. Adjacent restart, attach, and graceful-stop issues/PRs were checked but are not bases for this slice.

This repository does not use Docker Compose source code as a base because the implementation is tied to Docker engine event APIs and Go types. The Compose plugin uses Docker Compose as the behavioral reference, parses compatible timestamp values locally, and sends typed dates to the Apple runtime API.

## Current container-compose Behavior

With this slice on the local fork-backed integration stack:

- `container compose events --json --since VALUE --until VALUE [SERVICE...]` parses filters using the same Docker-compatible parser as logs.
- Accepted filters include RFC 3339 timestamps, Unix timestamps, and relative durations.
- The plugin passes typed `Date` bounds through `ContainerEventOptions` to `ContainerClient.events(options:)`.
- Dry-run renders the runtime command with `container events --since VALUE --until VALUE`.
- The existing Compose policy remains unchanged: project filtering, selected-service filtering, one-off suppression, Compose-private label stripping, and JSON Lines output stay in this repository.
- Default text event formatting is tracked by the separate follow-up docs `ISSUE-compose-events-text-format.md` and `PR-compose-events-text-format.md`.

## Local Docker Compose Parity Evidence

`Tools/parity/check-compose-events.sh` remains optional and outside CI. It now checks Docker Compose V2 `--since` / `--until` replay shape and default text replay shape in addition to container scope, selected-service filtering, internal label stripping, and one-off suppression:

```sh
make docker-compose-events-parity
```

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `STATUS.md`.
- [x] I checked current Apple issues and PRs before selecting this slice.
- [x] I recorded whether matching upstream items were used as a base, dependency, or behavioral reference.
