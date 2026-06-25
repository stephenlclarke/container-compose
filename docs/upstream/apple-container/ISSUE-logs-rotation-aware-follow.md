<!-- markdownlint-disable MD013 -->

# [Request]: Follow locally rotated raw container logs

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/02-feature.yml`.

## Feature or enhancement request details

Compose workflows and API clients need followed raw logs to keep streaming when the local active log file rotates. The current raw follow path follows a single active file descriptor. That works until the runtime renames `stdio.log` to `stdio.log.1` and creates a new active `stdio.log`; after that point, the client can miss new bytes written to the recreated active file.

Requested behavior:

- Preserve the existing static `logs(id:options:replay:)` API for finite replay.
- Add an explicit follow API for raw stdio logs so the API service owns local rotation detection rather than requiring clients or plugins to poll merged snapshots.
- Start a followed stream with the requested Docker-style replay window, including active plus rotated retained files.
- Treat negative `tail` as all retained logs.
- Treat `tail == 0` as no existing output, then follow future bytes.
- Continue streaming bytes written to the old active file after it is renamed during rotation.
- Reopen the recreated active file and stream future bytes without re-reading retained history.
- Keep Compose-specific presentation out of `apple/container`; service prefixes, colors, project fan-out, and replica ordering remain in the external plugin.

Direction note: after JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), this Apple-facing slice should be reviewed as a runtime log-follow primitive. Docker-shaped timestamp parsing and Compose output remain in `container-compose`.

Related upstream context:

- [apple/container#1752](https://github.com/apple/container/issues/1752): umbrella Compose-compatible log semantics issue.
- [apple/container#1591](https://github.com/apple/container/issues/1591): base log retrieval-options request.
- [apple/container#1592](https://github.com/apple/container/pull/1592): Chris George's base `ContainerLogOptions` direction.
- [apple/container#1764](https://github.com/apple/container/pull/1764): `tail` and `until` retrieval filters.
- [apple/container#1765](https://github.com/apple/container/pull/1765): optional Apple CLI timestamp filters; `container-compose` now owns Docker-shaped timestamp parsing.
- [Docker `container logs`](https://docs.docker.com/reference/cli/docker/container/logs/): supports `--follow` with `--tail`.
- [Docker Compose `logs`](https://docs.docker.com/reference/cli/docker/compose/logs/): documents `--follow` and `--tail` for service logs.
- [Docker `json-file` logging driver](https://docs.docker.com/engine/logging/drivers/json-file/): documents retained local log files with `max-size` and `max-file`.
- [Docker `local` logging driver](https://docs.docker.com/engine/logging/drivers/local/): documents retained local logging behavior.

This can later become a focused `apple/container` issue if maintainers prefer tracking raw follow rotation separately from the broader #1752 discussion.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
