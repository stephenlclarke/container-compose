<!-- markdownlint-disable MD013 -->

# [Request]: Rotate local persisted log files

## Template

This issue draft follows `.github/ISSUE_TEMPLATE/02-feature.yml`.

## Feature or enhancement request details

Local Compose workflows need `apple/container` to apply typed local log retention policy while the runtime writes persisted logs. `container-compose` owns translating Docker/Compose `logging.driver` and `logging.options.max-size` / `max-file` values into the typed `ContainerLogConfiguration`; those settings only become useful when the runtime writer rotates the local raw and structured log files together.

Requested behavior:

- Keep the default no-rotation behavior when no local maximum size is configured.
- Rotate persisted raw `stdio.log` and structured `stdio.jsonl` files before a write would exceed the configured local maximum size.
- Keep raw and structured files aligned so each retained raw file has the matching retained structured sidecar.
- Retain at most the configured `max-file` file count, including the active file, and remove the oldest rotated file when retention would exceed that count.
- Treat `max-file == 1` as active-file-only retention.
- Seed writer size counters from existing active files when a writer is reopened so rotation still applies correctly after runtime restart or writer reconstruction.
- Keep rotation in the runtime writer; Compose service fan-out, prefixes, colors, command formatting, and service-level validation remain outside `apple/container`.

Direction note: after JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), this Apple-facing slice should be reviewed as runtime retention mechanics, not Docker log-driver parser compatibility.

Related upstream context:

- [apple/container#1752](https://github.com/apple/container/issues/1752): Compose-compatible log semantics umbrella.
- [apple/container#1592](https://github.com/apple/container/pull/1592): Chris George's log retrieval-options direction.
- [apple/container#1764](https://github.com/apple/container/pull/1764): `tail` and `until` retrieval filters.
- [apple/container#1765](https://github.com/apple/container/pull/1765): optional Apple CLI timestamp filters; `container-compose` now owns Docker-shaped timestamp parsing.
- [Docker `json-file` logging driver](https://docs.docker.com/engine/logging/drivers/json-file/): documents `max-size` and `max-file`, including removal of the oldest file when rolling creates excess files.
- [Docker `local` logging driver](https://docs.docker.com/engine/logging/drivers/local/): documents local `max-size` and `max-file` retained logging behavior.
- [Compose service `logging`](https://docs.docker.com/reference/compose-file/services/#logging): documents service `logging.driver` and driver-specific `logging.options`.

The local integration branch already contains the writer behavior in commit `06862b7 feat(logs): rotate local log files`. The handoff should stay stacked after the typed local policy model and disabled-capture slices; Compose owns parsing driver names and retention option strings into the typed model.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
