<!-- markdownlint-disable MD013 -->

# Compose compatibility gap: default text events output

## Compose Surface

`docker compose events [--since VALUE] [--until VALUE] [SERVICE...]`

## Docker Compose V2 Behavior

Docker Compose defaults to text output when `--json` is not passed. For `docker/compose@9b55a6e9c1016fd3c31859b7e09260378d45a783`, the command layer prints JSON only when `opts.json` is true; otherwise it prints `api.Event.String()`.

The Docker Compose text event shape is:

```text
YYYY-MM-DD HH:MM:SS.ffffff container ACTION CONTAINER (key=value, ...)
```

The backend still applies the same Compose event policy before formatting: project filtering, container-event filtering, selected-service filtering, one-off suppression, and internal `com.docker.compose.*` attribute stripping.

References:

- Docker Compose events docs: <https://docs.docker.com/reference/cli/docker/compose/events/>
- Docker Compose command source: <https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/cmd/compose/events.go>
- Docker Compose backend source: <https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/pkg/compose/events.go>
- Docker Compose event formatter source: <https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/pkg/api/api.go>

## Existing Source And Stacking Decision

This is a plugin-only presentation slice. Do not open an Apple runtime PR for this change.

It stacks on the already documented event slices:

- `docs/upstream/events/ISSUE-container-events-stream.md`
- `docs/upstream/events/PR-container-events-stream.md`
- `docs/upstream/events/ISSUE-compose-events.md`
- `docs/upstream/events/PR-compose-events.md`
- `docs/upstream/events/ISSUE-container-event-time-filters.md`
- `docs/upstream/events/PR-container-event-time-filters.md`
- `docs/upstream/events/ISSUE-compose-event-time-filters.md`
- `docs/upstream/events/PR-compose-event-time-filters.md`

[apple/container#484](https://github.com/apple/container/issues/484) remains the runtime anchor for the event stream. A live Apple issue/PR check on 2026-06-22 found no separate upstream Apple item for Compose text formatting, and none is needed because the Apple runtime should keep emitting generic events rather than Docker Compose presentation policy.

Adjacent lifecycle issues and PRs for restart, attach, signal forwarding, and graceful-stop diagnostics remain separate from this text-output slice.

## Current container-compose Behavior

With this slice on the local fork-backed integration stack:

- `container compose events [SERVICE...]` renders Docker Compose-style text event lines by default.
- `container compose events --json [SERVICE...]` keeps the existing JSON Lines behavior.
- `--since` and `--until` continue to parse through `ComposeTimeParser` in `container-compose` and pass typed dates to `ContainerEventOptions`.
- Project/service filtering, one-off suppression, and Compose-private attribute stripping remain unchanged.
- Public text attributes are sorted for deterministic output, even though Docker Compose builds its text attribute list from Go map iteration.

## Local Docker Compose Parity Evidence

`Tools/parity/check-compose-events.sh` remains optional and outside CI. It now checks Docker Compose V2 default text replay shape in addition to JSON shape, selected-service filtering, internal label stripping, one-off suppression, and `--since` / `--until` replay-window behavior:

```sh
make docker-compose-events-parity
```

The extension has not yet been rerun against Docker after this slice. Run it before raising the text-events PR if a local Docker daemon is available.

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked `COMPATIBILITY.md`.
- [x] I checked current Apple issues and PRs before selecting this slice.
- [x] I recorded why no Apple runtime source issue or PR should be used as a base.
