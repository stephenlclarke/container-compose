# Status

Last updated: 2026-06-30 08:35 BST.

This file is the current-state handoff for `container-compose`. Keep it short. Do not store branch policy or historical evidence here; use [BRANCHES.md](BRANCHES.md), git history, GitHub Actions runs, SonarQube, and the handoff drafts under `docs/upstream/` when old details are needed.

## Current State

`main` is the active development lane, and installable Homebrew lanes consume prebuilt release-quality assets. Keep branch policy, release lane naming, and Homebrew lane details in [BRANCHES.md](BRANCHES.md); this file should only record the current handoff state.

## Current Integration Assumption

`container-compose` is supported as part of the fork-backed Stephen runtime bundle. Keep each package lane pinned to the matching `stephenlclarke/container`, `stephenlclarke/containerization`, and `container-builder-shim` surfaces until equivalent Apple upstream APIs are accepted and the plugin has been updated to those upstream surfaces.

Full build support, including BuildKit checks, SSH forwarding, additional contexts, provenance/SBOM attestations, and Dockerfile frontend options, assumes that bundled Stephen runtime path.

The main drift risks are logs, events, restart policy, health, exit/completion metadata, networking identity, IPAM/DNS, process listing, dynamic ports, copy/archive behavior, build inputs, mounts, secrets/configs, blkio, sysctls, and runtime API shape changes.

Current reviewed main-lane pins:

- `stephenlclarke/container`: `d13a7688e8c7bb5f96a545955011053587b3fbf5`
- `stephenlclarke/containerization`: `cada6d31310761c7e7bf9be87a29fe4820ff628d`
- `ghcr.io/stephenlclarke/container-builder-shim/builder`: `0.13.6`

## Latest Local Validation

The latest local validation for this `container-compose` slice passed with upstream issue/PR/discussion review for `deploy.resources.reservations.cpus` and `deploy.resources.reservations.memory`, local Docker Compose 5.2.0 parity probes, focused Go and Swift tests, `python3 -m unittest Tools/release/test_update_homebrew_formula.py`, `make docker-compose-deploy-resource-reservations-parity`, `make docker-compose-cli-surface-parity`, `make check`, `make cli-smoke-built`, `make coverage-check`, `bash -n Tools/parity/check-compose-deploy-resource-reservations.sh`, `shellcheck Tools/parity/check-compose-deploy-resource-reservations.sh`, Markdown lint, and `git diff --check`. This slice is a patch-level Compose release because it completes one Compose-file deploy metadata compatibility option; full CLI-completion releases should use a minor bump. Detailed command history belongs in git history and CI logs, not this handoff.

Most recent coverage proof:

- Swift: 800 Compose tests at 89.00% line coverage.
- Go normalizer: 92.45% line coverage.

## Recent Functional State

- Progress feedback: project loading, variable loading, image build, image pull, direct runtime create/start/run, foreground interactive `run`, and attached `exec` emit visible stderr progress before slow or terminal-taking operations can look hung.
- Build and image behavior: Compose `dockerfile` paths resolve relative to build context, list-form entrypoints map correctly to Apple `--entrypoint`, `compose build --print` renders deterministic Buildx bake JSON without build/push side effects, `compose build --check` runs BuildKit lint through the fork-backed build path, `build --print --check` renders `call: "lint"` without outputs, `build --builder default` and named `build --builder NAME` selections flow through to the fork-backed `container build` backend, provenance/SBOM attestations and `build.ssh` / `--ssh` flow through the same path, file/env-backed `build.secrets` map to BuildKit secret IDs while Docker Compose-compatible `uid`/`gid`/`mode` metadata is accepted and ignored for build execution, `additional_contexts` supports paths, remote contexts, and service contexts with build-order expansion, `build.entitlements`, `extra_hosts`, `isolation`, `network`, `privileged`, `shm_size`, and `ulimits` map to the BuildKit-compatible build model, and explicit false attestation forms remain no-op opt-outs.
- Core command support: `compose run`, `run --no-deps`, `down [SERVICES]`, `create`, `config`, `ps [SERVICE...]`, `watch`, `up --watch`, `up --menu`, `up --attach`, `up --attach-dependencies`, exit-control `up` flags, `exec --privileged`, and service, lifecycle, or watch `privileged: true` are covered by focused tests or runtime smoke.
- Deploy metadata: Docker Compose-compatible `deploy.endpoint_mode` and CPU/memory Deploy reservations are accepted as local metadata, while Swarm-only deploy modes, start-first update ordering, pids/device/generic reservations, and unmapped Deploy resource limits remain blocked by Apple runtime semantics and fail before side effects.
- Cleanup behavior: `down` and `rm` treat already-missing containers as absent, resource deletion treats missing networks and volumes as absent, and `rm` now follows Docker Compose stopped-container semantics: running containers are skipped unless `--stop` is requested and empty cleanup reports `No stopped containers`.
- Runtime dependency preflight: runtime-backed Compose commands check that the active `container` install reports `stephenlclarke/container` plus `stephenlclarke/containerization` provenance before doing work; Apple stock or missing components fail with Homebrew lane guidance and the GitHub install URL.
- Attach and foreground output: `attach --no-stdin` follows selected service logs and supports default signal proxying; `up --no-color`, `up --no-log-prefix`, and `up --timestamps` are supported through the raw foreground or structured log paths.
- Packaging and quality: CodeQL gates the release-built Go normalizer path, Swift CodeQL remains blocked by fork-backed dependency rebuild timeouts, and all Go package outputs are release-built with `CGO_ENABLED=0`, `-trimpath`, and stripped linker flags.

## Current Limits

- Interactive attach with stdin reattach remains blocked until Apple exposes an interactive attach primitive.
- `up --menu` is supported for attached terminal log-follow sessions, including detach, watch toggle, graceful stop, and force stop shortcuts. Docker Desktop-only shortcuts are intentionally absent, and `up --menu` remains incompatible with exit-control options and the separate `up --watch` mode pending a deeper parity pass.
- Build support assumes the matching `stephenlclarke/container` build backend and the current builder image. Build secrets that cannot be materialized as file/env-backed secret IDs remain unsupported.

## Upstream Compatibility

Released Apple `container` compatibility is not a supported-lane functionality gap. The Homebrew preview lane requires the Stephen fork-backed runtime stack and preflights for it before runtime-backed Compose commands run. Stock Apple compatibility remains an upstream/release-channel blocker until equivalent runtime primitives are accepted by Apple and this plugin is updated to consume those upstream APIs.

## Open Blockers

- The immutable `ghcr.io/stephenlclarke/container-builder-shim/builder:0.13.6` GHCR image has been published and manifest-verified for linux/arm64.
- SonarCloud quality gate is currently OK on `main` with 0 unresolved issues as reported by `/Users/sclarke/github/pr-refresh` `make sonar-status`.

## Open Follow-ups

- Continue live runtime smoke around progress rendering when touching slow paths. If a local `container compose` run or build appears to hang before any screen output, treat that as a progress regression: reproduce the silent phase, add a focused first-frame test, and emit a Docker Compose-style spinner/status row before the blocking operation begins.

## Next Step

Continue the next strict Compose-file gap scan and implement the next coherent parity slice when one is confirmed.
