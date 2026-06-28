# Status

Last updated: 2026-06-28 21:34 BST.

This file is the current-state handoff for `container-compose`. Keep it short. Do not store branch policy or historical evidence here; use [BRANCHES.md](BRANCHES.md), git history, GitHub Actions runs, SonarQube, and the handoff drafts under `docs/upstream/` when old details are needed.

## Current State

`main` is the active development lane, and installable Homebrew lanes consume prebuilt release-quality assets. Keep branch policy, release lane naming, and Homebrew lane details in [BRANCHES.md](BRANCHES.md); this file should only record the current handoff state.

## Current Integration Assumption

`container-compose` still depends on fork-backed runtime surfaces for several forward Compose behaviors. Keep each package lane pinned to the matching `stephenlclarke/container` and `stephenlclarke/containerization` surfaces until the equivalent Apple upstream APIs are accepted and the plugin has been updated to those upstream surfaces.

The main drift risks are logs, events, restart policy, health, exit/completion metadata, networking identity, IPAM/DNS, process listing, dynamic ports, copy/archive behavior, build inputs, mounts, secrets/configs, blkio, sysctls, and runtime API shape changes.

Current reviewed main-lane pins:

- `stephenlclarke/container`: `350a63ea4daa7ed819a2c66a3b87124044a4370a`
- `stephenlclarke/containerization`: `658936c53dbf112fc3f51ec7573a9ffca54baf01`
- `ghcr.io/stephenlclarke/container-builder-shim/builder`: `0.13.4`

## Latest Local Validation

The latest local validation for this `container-compose` slice passed with `make check`, `make coverage-check`, `make swift-runtime-test`, `make docker-compose-cli-surface-parity`, `make docker-compose-build-builder-parity`, `make docker-compose-build-check-parity`, `make docker-compose-create-options-parity`, `make docker-compose-events-parity`, `make docker-compose-rm-parity`, `make docker-compose-restart-policy-parity`, `make docker-compose-e2e-fixtures`, full Markdown lint, and `git diff --check`. Retained validation for the paired runtime pins includes `make check` and `make test` in `container`, `make check` and `make test` in `containerization`, and `go test ./...`, `make lint`, `make vet`, `make coverage`, `make build-linux`, and release target dry-run validation in `container-builder-shim`. Detailed command history belongs in git history and CI logs, not this handoff.

Most recent coverage proof:

- Swift: 781 Compose tests at 89.96% line coverage; 831 `container` unit tests at 42.05% unit-only line coverage.
- Go normalizer: 92.52% line coverage.

## Recent Functional State

- Progress feedback: project loading, variable loading, image build, image pull, direct runtime create/start/run, foreground interactive `run`, and attached `exec` emit visible stderr progress before slow or terminal-taking operations can look hung.
- Build and image behavior: Compose `dockerfile` paths resolve relative to build context, list-form entrypoints map correctly to Apple `--entrypoint`, `compose build --print` renders deterministic Buildx bake JSON without build/push side effects, `compose build --check` runs BuildKit lint through the fork-backed build path, `build --print --check` renders `call: "lint"` without outputs, `build --builder default` is accepted for the local single builder, provenance/SBOM attestations and `build.ssh` / `--ssh` flow through the fork-backed build path, and explicit false attestation forms remain no-op opt-outs.
- Core command support: `compose run`, `run --no-deps`, `down [SERVICES]`, `create`, `config`, `ps [SERVICE...]`, `watch`, `up --watch`, `up --attach`, `up --attach-dependencies`, exit-control `up` flags, `exec --privileged`, and service, lifecycle, or watch `privileged: true` are covered by focused tests or runtime smoke.
- Cleanup behavior: `down` and `rm` treat already-missing containers as absent, resource deletion treats missing networks and volumes as absent, and `rm` now follows Docker Compose stopped-container semantics: running containers are skipped unless `--stop` is requested and empty cleanup reports `No stopped containers`.
- Runtime dependency preflight: runtime-backed Compose commands check that the active `container` install reports `stephenlclarke/container` plus `stephenlclarke/containerization` provenance before doing work; Apple stock or missing components fail with Homebrew lane guidance and the GitHub install URL.
- Attach and foreground output: `attach --no-stdin` follows selected service logs and supports default signal proxying; `up --no-color`, `up --no-log-prefix`, and `up --timestamps` are supported through the raw foreground or structured log paths.
- Packaging and quality: CodeQL gates the release-built Go normalizer path, Swift CodeQL remains blocked by fork-backed dependency rebuild timeouts, and all Go package outputs are release-built with `CGO_ENABLED=0`, `-trimpath`, and stripped linker flags.

## Current Limits

- Interactive attach with stdin reattach remains blocked until Apple exposes an interactive attach primitive.
- Bare `--menu` / `--menu=true` remain blocked until interactive shortcut handling exists; `--menu=false` is accepted.
- Non-default `build --builder NAME` remains blocked until the backend exposes Docker-compatible named builder selection.
- Non-false provenance/SBOM attestation requests require the customized `stephenlclarke/container` and `container-builder-shim` build path; explicit false forms are accepted as no-op opt-outs.
- Runtime build execution for SSH, non-false attestations, and build checks requires the matching `stephenlclarke/container` build backend and the `0.13.4` SSH/check-capable builder image.

## Open Blockers

- Released Apple compatibility still depends on upstream acceptance of fork-backed runtime primitives.
- Package/Homebrew promotion now depends on publishing `ghcr.io/stephenlclarke/container-builder-shim/builder:0.13.4` from the matching builder-shim source before distributing the `container` build pinned above.
- SonarQube status should be checked through `/Users/sclarke/github/pr-refresh` with `make sonar-status` after the next push.

## Open Follow-ups

- Continue live runtime smoke around progress rendering when touching slow paths. If a local `container compose` run or build appears to hang before any screen output, treat that as a progress regression: reproduce the silent phase, add a focused first-frame test, and emit a Docker Compose-style spinner/status row before the blocking operation begins.

## Next Step

Commit the completed cleanup/parity slice on `main`, then push only once the current coherent functionality batch is ready for review.
