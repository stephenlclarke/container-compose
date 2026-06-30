# Docker Compose CLI Surface Parity

`make docker-compose-cli-surface-parity` is a local-only integration check for Docker Compose V2 command/help surface drift. It builds the local `compose` binary, compares it with Docker Compose V2, and writes a Markdown report to `.build/parity/compose-cli-surface.md`.

The check compares:

- root command listings;
- `bridge` and `bridge transformations` command listings;
- long options rendered by every documented command help page.

The check intentionally ignores help prose wrapping, support-colour annotations, and option descriptions. Runtime behavior parity remains covered by the existing local-only Docker-backed parity targets for build builder selection, build checks, create-time options, events, and restart policies.

For `build --builder` behavior specifically, run `make docker-compose-build-builder-parity`. That target compares Docker Compose V2 `build --builder default --print` and `build --builder NAME --print` with the same `container compose` commands using a daemon-free local fixture, then verifies the selected builder does not leak into Buildx bake JSON in print mode.

For `build.isolation` behavior specifically, run `make docker-compose-build-isolation-parity`. That target compares Docker Compose V2 and `container-compose` using a Compose file with `build.isolation: hyperv`, verifies both preserve the value in config output, confirms both omit the field from Buildx bake JSON on this platform, and proves the local Docker Compose build path accepts the field.

For build-secret metadata behavior specifically, run `make docker-compose-build-secret-metadata-parity`. That target compares Docker Compose V2 and `container-compose` using a Compose file with build-secret `uid`, `gid`, and `mode` metadata, verifies Docker Compose preserves those fields in config output, confirms both tools omit the fields from Buildx bake secret entries, and proves the local Docker Compose build path accepts the field.

For Deploy endpoint-mode behavior specifically, run `make docker-compose-deploy-endpoint-mode-parity`. That target compares Docker Compose V2 and `container-compose` using a Compose file with `deploy.endpoint_mode: dnsrr`, verifies Docker Compose preserves the Swarm metadata in config output, and confirms both tools accept local dry-run `up --no-start`.

For Deploy CPU/memory reservation behavior specifically, run `make docker-compose-deploy-resource-reservations-parity`. That target compares Docker Compose V2 and `container-compose` using a Compose file with `deploy.resources.reservations.cpus` and `deploy.resources.reservations.memory`, verifies Docker Compose preserves those scheduler hints in config output, and confirms both tools accept local dry-run `up --no-start`.

For `build --check` behavior specifically, run `make docker-compose-build-check-parity`. That target reuses Docker Compose's upstream `pkg/e2e/fixtures/build-test/minimal` fixture, compares Docker Compose V2 BuildKit lint behavior with `container compose build --print --check`, and can run the live fork-backed `container compose build --check` path when `CONTAINER_COMPOSE_BUILD_CHECK_LIVE=1` is set.

For `up --menu` behavior specifically, run `make docker-compose-up-menu-parity`. That local-only target compares Docker Compose V2 and `container-compose` against a generated compose.yml fixture for `--menu=false`, `--menu=true`, and `COMPOSE_MENU=true` with explicit `--menu=false`, then verifies the current exit-control and `--watch` differences remain documented.

## Documented Differences

- Root `--verbose` is listed by `container-compose` and accepted by the parser for existing bug-report and version workflows. Docker Compose 5.2.0 standalone accepts `docker-compose --verbose version`, but does not list `--verbose` in root help. This is tracked in `Tools/parity/compose-cli-surface.allowlist`.
- `build --builder default` selects the ordinary fork-backed `container build` builder, while `build --builder NAME` forwards the name to `container build` so the matching fork-backed runtime can use a separate `buildkit-NAME` builder container. Docker Compose and `container-compose` both omit builder selection from `build --print` bake JSON.
- `build.isolation` is accepted and preserved in normalized config. Docker Compose V2 on this macOS/Linux-backed local builder omits the field from `build --print` Buildx bake JSON and still accepts a real build; `container-compose` mirrors that behavior by accepting the field without forwarding an isolation flag to `container build`.
- Build-secret `uid`, `gid`, and `mode` metadata is accepted for build file/env secrets. Docker Compose V2 preserves that metadata in config output, but BuildKit does not implement it and Docker Compose omits it from bake secret entries; `container-compose` mirrors the build behavior and its normalized config reports the effective BuildKit secret ID plus file/env source.
- `deploy.endpoint_mode` is accepted as Swarm metadata in local mode. Docker Compose V2 preserves the raw Deploy value in config output and accepts local dry-run `up --no-start`; `container-compose` mirrors the local execution behavior and does not report the field as unsupported.
- `deploy.resources.reservations.cpus` and `deploy.resources.reservations.memory` are accepted as scheduler metadata in local mode. Docker Compose V2 preserves the raw Deploy reservation values in config output and accepts local dry-run `up --no-start`; `container-compose` mirrors the local execution behavior and does not report those fields as unsupported.
- Docker Compose 5.2.0 accepts `up --menu` with exit-control flags and `up --menu --watch` in dry-run mode. `container-compose` still rejects those combinations because combined menu/exit-control and menu/watch lifecycle semantics need a deeper parity pass on the Apple runtime path. `make docker-compose-up-menu-parity` treats those as documented differences while requiring parity for the supported optional-boolean menu forms.

No unexpected command or long-option surface differences were observed on this MacBook Pro against Docker Compose 5.2.0 when the CLI-surface parity harness was refreshed for this slice.
