# Docker Compose Parity

This file records Docker Compose V2 parity evidence for `container-compose`. It is the maintained compatibility log for local Docker-backed integration checks. Keep implementation planning in [PLAN.md](PLAN.md) and architecture decisions in [DESIGN.md](DESIGN.md); keep Docker behavior evidence and known parity gaps here.

The normal `make ci` path does not require Docker. The checks below are local-only because Apple-facing CI must not depend on Docker Engine, Docker Compose, or a running local `apple/container` service.

## Source Fixtures

The full parity path sources Docker Compose's own e2e fixtures from:

- Repository: <https://github.com/docker/compose>
- Fixture root: `pkg/e2e/fixtures`
- Local sparse checkout: `.build/parity/docker-compose-e2e`
- Refresh helper: `Tools/parity/sync-docker-compose-e2e-fixtures.sh`
- Manual target: `make docker-compose-e2e-fixtures`

The helper checks the remote `main` branch with `git ls-remote`. It clones when the local sparse checkout is missing and refreshes only when Docker Compose's remote HEAD changed. If the local checkout already matches remote HEAD, it does not fetch or reclone.

The current create-options parity fixture copies Docker Compose's upstream `pkg/e2e/fixtures/build-test/minimal/Dockerfile` into a temporary project before running Docker Compose V2 and `container-compose`.

## Current Results

| Date | Target | Docker Source | Result | Notes |
| --- | --- | --- | --- | --- |
| 2026-06-24 | `make cli-smoke-built` | Docker Compose 5.2.0 CLI help snapshot | Pass | The `container-compose` executable accepts the Docker Compose 5.2.0 root command surface, global options, command help, and placeholder gaps for `bridge`, `commit`, and `publish`. Top-level `convert` is intentionally removed because Docker Compose exposes conversion under `bridge`. |
| 2026-06-24 | `make docker-compose-e2e-fixtures` | `docker/compose@a3c1c0dc2eba14f5ad9df3f5c8f0e1ebdd088a9c` | Pass | Missing-checkout clone succeeded. Immediate rerun reported the same commit without recloning. |
| 2026-06-24 | `make docker-compose-restart-policy-parity` | Local parity fixture | Pass | Passed with Docker Compose 5.2.0 and Docker Engine 29.5.2 after updating the inspector to use `docker compose ps --all -q` for created-but-not-running containers. |
| 2026-06-24 | `make docker-compose-create-options-parity` | `docker/compose@a3c1c0dc2eba14f5ad9df3f5c8f0e1ebdd088a9c` plus local create-options fixture | Partial | Docker Compose inspect checks passed and `container-compose --dry-run create --build` checks passed. Live `container-compose create --build` is blocked by `Error: XPC connection error: Connection invalid`; `container system status` also hangs and `container system start` did not complete. |

## CLI Surface

`container-compose` accepts the Docker Compose 5.2.0 root command list and global option surface. Help output is rendered from a Docker Compose 5.2.0 snapshot so that missing implementation work is visible without rejecting valid Docker Compose commands at parse time. Help marks supported commands in green, partially supported commands in orange, and unsupported commands in red; `--ansi never` keeps the same support text without color.

Command-level gaps currently return the literal placeholder `Not implemented yet` when there is no backing implementation. The current placeholders are `bridge`, `commit`, and `publish`. Some implemented commands also accept newer Docker Compose options that are parsed for surface compatibility but not yet behaviorally wired; those remain parity gaps until covered by a focused fixture or runtime primitive.

## Covered By Current Parity Checks

### `docker-compose-create-options-parity`

This target validates the same temporary Compose project through Docker Compose V2 and `container-compose`. It currently covers:

- Build wiring using a Dockerfile copied from Docker Compose e2e fixtures.
- Explicit service healthchecks.
- Local logging policy and disabled local logging.
- Service-level `restart` and deploy restart timing.
- Host-IP published ports.
- File-backed configs and secrets.
- DNS options.
- Hostname, domain name, static `extra_hosts`, and `host-gateway`.
- Service sysctls.
- `blkio_config.weight`.
- Single-network service aliases.

### `docker-compose-restart-policy-parity`

This target validates Docker Compose V2 `HostConfig.RestartPolicy` behavior for:

- Service-level `restart`.
- Deploy-over-service precedence.
- Deploy `condition: any`.
- Deploy `condition: none`.
- `on-failure:0` as unlimited retry.

### `docker-log-fixtures`

This target captures Docker Compose V2 log tail behavior for rotated `json-file` and `local` logging drivers and compares the captured result with the checked fixture under `Tests/ComposeCoreTests/Fixtures/logging/`.

### `docker-compose-events-parity`

This target validates Docker Compose V2 project event behavior mirrored by `container-compose`: JSON output, default text output, container-event scope, selected-service filtering, internal Compose label stripping, one-off container suppression, and bounded `--since` / `--until` replay shape.

## High-Value Upstream Fixture Groups

The Docker Compose e2e corpus includes focused fixture groups that should be
added to the full parity manifest as `container-compose` surfaces mature:

| Fixture group | Useful coverage |
| --- | --- |
| `build-test/*` | Build args, build secrets, SSH, tags, platforms, Dockerfile errors, and build dependencies. |
| `configs`, `env-secret`, `env_file`, `environment` | Config, secret, environment, dotenv, and interpolation behavior. |
| `dependencies`, `wait`, `restart-test`, `start-stop` | Dependency ordering, completion, health, wait, restart, and lifecycle behavior. |
| `logging-driver`, `logs-test`, `stdout-stderr` | Logging policy, stdout/stderr identity, log replay, and follow behavior. |
| `network-alias`, `network-links`, `network-test`, `ipam`, `links` | DNS aliases, legacy links, multi-network attachments, IPAM, and network-mode gaps. |
| `cp-test`, `export`, `pause`, `port-range`, `scale`, `volumes`, `resources`, `watch` | Command coverage for copy/export/runtime controls, port ranges, scaling, volumes, resource fields, and watch. |

## Maintenance Rules

- Record every Docker-backed parity run in the Current Results table.
- Include Docker Compose version, Docker Engine version, and the Docker Compose source fixture commit when available.
- Classify new fixture groups as pass, partial, unsupported, or runtime gap rather than treating every upstream Docker feature as an immediate regression.
- Keep unsupported Docker Compose behavior in this file until the implementation or the Apple runtime primitive lands.
