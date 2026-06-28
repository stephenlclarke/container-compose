# Docker Compose CLI Surface Parity

`make docker-compose-cli-surface-parity` is a local-only integration check for Docker Compose V2 command/help surface drift. It builds the local `compose` binary, compares it with Docker Compose V2, and writes a Markdown report to `.build/parity/compose-cli-surface.md`.

The check compares:

- root command listings;
- `bridge` and `bridge transformations` command listings;
- long options rendered by every documented command help page.

The check intentionally ignores help prose wrapping, support-colour annotations, and option descriptions. Runtime behavior parity remains covered by the existing local-only Docker-backed parity targets for build checks, create-time options, events, and restart policies.

For `build --check` behavior specifically, run `make docker-compose-build-check-parity`. That target reuses Docker Compose's upstream `pkg/e2e/fixtures/build-test/minimal` fixture, compares Docker Compose V2 BuildKit lint behavior with `container compose build --print --check`, and can run the live fork-backed `container compose build --check` path when `CONTAINER_COMPOSE_BUILD_CHECK_LIVE=1` is set.

## Documented Differences

- Root `--verbose` is listed by `container-compose` and accepted by the parser for existing bug-report and version workflows. Docker Compose 5.1.4 standalone accepts `docker-compose --verbose version`, but does not list `--verbose` in root help. This is tracked in `Tools/parity/compose-cli-surface.allowlist`.

No other command or long-option surface differences were observed on this MacBook Pro against Docker Compose 5.1.4 when the parity harness was added.
