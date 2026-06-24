<!-- markdownlint-disable MD013 -->

# [Request]: Follow locally rotated structured container log records

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/02-feature.yml`.

## Feature or enhancement request details

Compose workflows need timestamped followed logs to keep working across retained local log rotation. The raw `stdio.log` follow path can stream bytes, but timestamped output and time-filtered followed logs need the structured `stdio.jsonl` records so the runtime can preserve stream and timestamp metadata.

Requested behavior:

- Add an explicit runtime/API follow surface for structured `ContainerLogRecord` streams.
- Rebuild stored runtime chunks into logical log lines before applying `tail`, `since`, and `until`.
- Start with the requested retained replay window, including rotated record files and the active prefix that existed before following began.
- Treat negative `tail` as all retained records.
- Treat `tail == 0` as no existing records, then follow future records.
- Ignore an open record fragment that existed at the `tail == 0` snapshot boundary.
- Carry partial log-line state across active-file rotation.
- Flush a final complete structured record when the container stops.
- Avoid plugin-side polling of full retained snapshots for long-running timestamped follow sessions.
- Keep Compose-specific presentation out of `apple/container`; service prefixes, colors, project fan-out, and replica ordering remain in the external plugin.

Direction note: after JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), this Apple-facing slice should be reviewed as a structured runtime follow primitive. Docker-shaped timestamp parsing and Compose output remain in `container-compose`.

Related upstream context:

- [apple/container#1752](https://github.com/apple/container/issues/1752): umbrella Compose-compatible log semantics issue.
- [apple/container#1591](https://github.com/apple/container/issues/1591): base log retrieval-options request.
- [apple/container#1592](https://github.com/apple/container/pull/1592): Chris George's base `ContainerLogOptions` direction.
- [apple/container#1764](https://github.com/apple/container/pull/1764): `tail` and `until` retrieval filters.
- [apple/container#1765](https://github.com/apple/container/pull/1765): optional Apple CLI timestamp filters; `container-compose` now owns Docker-shaped timestamp parsing.
- [Docker `container logs`](https://docs.docker.com/reference/cli/docker/container/logs/): supports `--follow`, `--tail`, `--since`, `--until`, and `--timestamps`.
- [Docker Compose `logs`](https://docs.docker.com/reference/cli/docker/compose/logs/): documents followed, tailed, and timestamped service logs.
- [Docker `json-file` logging driver](https://docs.docker.com/engine/logging/drivers/json-file/): documents JSON log records with timestamp and stream fields.
- [Docker `local` logging driver](https://docs.docker.com/engine/logging/drivers/local/): documents retained local logging behavior.

This can later become a focused `apple/container` issue if maintainers prefer tracking structured follow rotation separately from the broader #1752 discussion.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
