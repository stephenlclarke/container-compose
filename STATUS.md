# Status

Last updated: 2026-06-28 23:33 BST.

This file is the current-state handoff for `container-compose`. Keep it short. Do not store branch policy or historical evidence here; use [BRANCHES.md](BRANCHES.md), git history, GitHub Actions runs, SonarQube, and the handoff drafts under `docs/upstream/` when old details are needed.

## Current State

`main` is the active development lane, and installable Homebrew lanes consume prebuilt release-quality assets. Keep branch policy, release lane naming, and Homebrew lane details in [BRANCHES.md](BRANCHES.md); this file should only record the current handoff state.

## Current Integration Assumption

`container-compose` still depends on fork-backed runtime surfaces for several forward Compose behaviors. Keep each package lane pinned to the matching `stephenlclarke/container` and `stephenlclarke/containerization` surfaces until the equivalent Apple upstream APIs are accepted and the plugin has been updated to those upstream surfaces.

Full provenance/SBOM attestation requests are supported on the required Stephen fork-backed runtime and builder-shim path. Stock Apple `container` remains unsupported for those requests until equivalent upstream build backend support exists.

The main drift risks are logs, events, restart policy, health, exit/completion metadata, networking identity, IPAM/DNS, process listing, dynamic ports, copy/archive behavior, build inputs, mounts, secrets/configs, blkio, sysctls, and runtime API shape changes.

Current reviewed main-lane pins:

- `stephenlclarke/container`: `449d8d0626c2e640163ecf678e6ee22a85ace91c`
- `stephenlclarke/containerization`: `4d129c6d360d1d20b257818d894a64f24bd39f74`
- `ghcr.io/stephenlclarke/container-builder-shim/builder`: `0.13.4`

## Latest Local Validation

The latest local validation for this `container-compose` slice passed with `make check`, `make coverage-check`, `make swift-runtime-test`, `make docker-compose-cli-surface-parity`, `make docker-compose-build-builder-parity`, `make docker-compose-build-check-parity`, `make docker-compose-create-options-parity`, `make docker-compose-events-parity`, `make docker-compose-rm-parity`, `make docker-compose-restart-policy-parity`, `make docker-compose-e2e-fixtures`, full Markdown lint, and `git diff --check`. Retained validation for the paired runtime pins includes `make check` and `make test` in `container`, `make check` and `make test` in `containerization`, and `go test ./...`, `make lint`, `make vet`, `make coverage`, `make build-linux`, and release target dry-run validation in `container-builder-shim`. Detailed command history belongs in git history and CI logs, not this handoff.

Most recent coverage proof:

- Swift: 782 Compose tests at 90.01% line coverage; 835 `container` unit tests at 42.07% unit-only line coverage.
- Go normalizer: 92.52% line coverage.

## Recent Functional State

- Progress feedback: project loading, variable loading, image build, image pull, direct runtime create/start/run, foreground interactive `run`, and attached `exec` emit visible stderr progress before slow or terminal-taking operations can look hung.
- Build and image behavior: Compose `dockerfile` paths resolve relative to build context, list-form entrypoints map correctly to Apple `--entrypoint`, `compose build --print` renders deterministic Buildx bake JSON without build/push side effects, `compose build --check` runs BuildKit lint through the fork-backed build path, `build --print --check` renders `call: "lint"` without outputs, `build --builder default` and named `build --builder NAME` selections flow through to the fork-backed `container build` backend, provenance/SBOM attestations and `build.ssh` / `--ssh` flow through the same path, and explicit false attestation forms remain no-op opt-outs.
- Core command support: `compose run`, `run --no-deps`, `down [SERVICES]`, `create`, `config`, `ps [SERVICE...]`, `watch`, `up --watch`, `up --attach`, `up --attach-dependencies`, exit-control `up` flags, `exec --privileged`, and service, lifecycle, or watch `privileged: true` are covered by focused tests or runtime smoke.
- Cleanup behavior: `down` and `rm` treat already-missing containers as absent, resource deletion treats missing networks and volumes as absent, and `rm` now follows Docker Compose stopped-container semantics: running containers are skipped unless `--stop` is requested and empty cleanup reports `No stopped containers`.
- Runtime dependency preflight: runtime-backed Compose commands check that the active `container` install reports `stephenlclarke/container` plus `stephenlclarke/containerization` provenance before doing work; Apple stock or missing components fail with Homebrew lane guidance and the GitHub install URL.
- Attach and foreground output: `attach --no-stdin` follows selected service logs and supports default signal proxying; `up --no-color`, `up --no-log-prefix`, and `up --timestamps` are supported through the raw foreground or structured log paths.
- Packaging and quality: CodeQL gates the release-built Go normalizer path, Swift CodeQL remains blocked by fork-backed dependency rebuild timeouts, and all Go package outputs are release-built with `CGO_ENABLED=0`, `-trimpath`, and stripped linker flags.

## Current Limits

- Interactive attach with stdin reattach remains blocked until Apple exposes an interactive attach primitive.
- Bare `--menu` / `--menu=true` remain blocked until interactive shortcut handling exists; `--menu=false` is accepted.
- Runtime build execution for named builders, SSH, provenance/SBOM attestations, and build checks requires the matching `stephenlclarke/container` build backend and the `0.13.4` SSH/check/attestation-capable builder image.

## Upstream Compatibility

Released Apple `container` compatibility is not a supported-lane functionality gap. The Homebrew preview lane requires the Stephen fork-backed runtime stack and preflights for it before runtime-backed Compose commands run. Stock Apple compatibility remains an upstream/release-channel blocker until equivalent runtime primitives are accepted by Apple and this plugin is updated to consume those upstream APIs.

## Open Blockers

- Package/Homebrew promotion now depends on publishing `ghcr.io/stephenlclarke/container-builder-shim/builder:0.13.4` from the matching builder-shim source before distributing the `container` build pinned above.
- SonarCloud quality gate is currently OK; recheck the new analysis after this push. The local `/Users/sclarke/github/pr-refresh` helper was not present on this machine.

## Open Follow-ups

- Continue live runtime smoke around progress rendering when touching slow paths. If a local `container compose` run or build appears to hang before any screen output, treat that as a progress regression: reproduce the silent phase, add a focused first-frame test, and emit a Docker Compose-style spinner/status row before the blocking operation begins.

## Next Step

Push the current coherent `main` batch once it is ready for review.
