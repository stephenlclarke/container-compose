# [Request]: Support static rotated log replay with bounded line tailing

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/02-feature.yml`.

## Feature or enhancement request details

`container logs -n <count>` and external API clients should be able to replay the last N logical log lines from locally retained log files without reading the full retained history into memory. Docker Compose documents `logs --tail` as the number of lines to show from the end of the logs for each container, and Compose projects commonly combine `--tail` with service-level local log rotation such as `logging.options.max-size` and `logging.options.max-file`.

The current Compose-enabling integration branch already has the lower-level retrieval work from Chris George's log options direction and the follow-up `tail` / `until` / timestamp parser work. The next runtime primitive needed by `container-compose` is static replay across the active `stdio.log` file plus rotated `stdio.log.<n>` files, with line-correct `tail` behavior applied after the retained files are considered as one chronological stream.

The requested behavior is:

- Preserve the existing default active-file-only behavior unless callers explicitly request rotated replay through replay policy.
- Support static raw replay across active plus rotated local log files in chronological order.
- Treat negative `tail` as all retained logs, matching Docker-style behavior.
- Treat `tail == 0` as an empty replay.
- Apply positive `tail` to logical log lines after concatenating retained files, including lines split across a rotation boundary.
- Use a bounded reverse scan for tail-only requests so `container logs -n 10` does not read the entire retained log history.
- Keep Compose-specific behavior out of `apple/container`; service prefixes, colors, project fan-out, and replica selection remain in the external plugin.

Related upstream context:

- [apple/container#1752](https://github.com/apple/container/issues/1752): umbrella Compose-compatible log semantics issue.
- [apple/container#1591](https://github.com/apple/container/issues/1591): base log retrieval-options request.
- [apple/container#1592](https://github.com/apple/container/pull/1592): Chris George's base `ContainerLogOptions` direction.
- [apple/container#1764](https://github.com/apple/container/pull/1764): `tail` and `until` retrieval filters.
- [apple/container#1765](https://github.com/apple/container/pull/1765): optional Apple CLI timestamp filters; `container-compose` now owns Docker-shaped timestamp parsing.
- [Docker Compose `logs`](https://docs.docker.com/reference/cli/docker/compose/logs/): documents `--tail` as line count per container.
- [Docker `json-file` logging driver](https://docs.docker.com/engine/logging/drivers/json-file/): documents retained local log files with `max-size` and `max-file`.
- [Docker `local` logging driver](https://docs.docker.com/engine/logging/drivers/local/): documents retained local logging behavior.

This can later become a focused `apple/container` issue if maintainers prefer tracking static rotated replay separately from the broader #1752 discussion.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
