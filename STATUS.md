# Status

Last updated: 2026-06-28 14:18 BST.

This file is the current-state handoff for `container-compose`. Keep it short. Do not store branch policy or historical evidence here; use [BRANCHES.md](BRANCHES.md), git history, GitHub Actions runs, SonarQube, and the handoff drafts under `docs/upstream/` when old details are needed.

## Current State

`main` is the active development lane, and installable Homebrew lanes consume prebuilt release-quality assets. Keep branch policy, release lane naming, and Homebrew lane details in [BRANCHES.md](BRANCHES.md); this file should only record the current handoff state.

## Current Integration Assumption

`container-compose` still depends on fork-backed runtime surfaces for several forward Compose behaviors. Keep each package lane pinned to the matching `stephenlclarke/container` and `stephenlclarke/containerization` surfaces until the equivalent Apple upstream APIs are accepted and the plugin has been updated to those upstream surfaces.

The main drift risks are logs, events, restart policy, health, exit/completion metadata, networking identity, IPAM/DNS, process listing, dynamic ports, copy/archive behavior, build inputs, mounts, secrets/configs, blkio, sysctls, and runtime API shape changes.

Current reviewed main-lane pins:

- `stephenlclarke/container`: `6856ebbc97f6b35f6b07ec518be2cf6b55caedc9`
- `stephenlclarke/containerization`: `658936c53dbf112fc3f51ec7573a9ffca54baf01`
- `ghcr.io/stephenlclarke/container-builder-shim/builder`: `0.13.3`

## Latest Local Validation

The latest local validation passed with focused Swift tests, runtime smoke tests, Go normalizer tests, `make check`, `make ci`, `make cli-smoke-built`, workflow linting, Markdown linting, and `git diff --check`. Detailed command history belongs in git history and CI logs, not this handoff.

Most recent coverage proof:

- Swift: 756 tests, 89.77% line coverage.
- Go normalizer: 92.39% line coverage.

## Recent Functional State

- Progress feedback: project loading, variable loading, image build, image pull, direct runtime create/start/run, foreground interactive `run`, and attached `exec` emit visible stderr progress before slow or terminal-taking operations can look hung.
- Build and image behavior: Compose `dockerfile` paths resolve relative to build context, list-form entrypoints map correctly to Apple `--entrypoint`, `compose build --print` renders deterministic Buildx bake JSON without build/push side effects, provenance/SBOM attestations and `build.ssh` / `--ssh` flow through the fork-backed build path, and explicit false attestation forms remain no-op opt-outs.
- Core command support: `compose run`, `run --no-deps`, `down [SERVICES]`, `create`, `config`, `ps [SERVICE...]`, `watch`, `up --watch`, `up --attach`, `up --attach-dependencies`, exit-control `up` flags, `exec --privileged`, and lifecycle or watch `privileged: true` are covered by focused tests or runtime smoke.
- Attach and foreground output: `attach --no-stdin` follows selected service logs and supports default signal proxying; `up --no-color`, `up --no-log-prefix`, and `up --timestamps` are supported through the raw foreground or structured log paths.
- Packaging and quality: CodeQL gates the release-built Go normalizer path, Swift CodeQL remains blocked by fork-backed dependency rebuild timeouts, and all Go package outputs are release-built with `CGO_ENABLED=0`, `-trimpath`, and stripped linker flags.

## Current Limits

- Interactive attach with stdin reattach remains blocked until Apple exposes an interactive attach primitive.
- Bare `--menu` / `--menu=true` remain blocked until interactive shortcut handling exists; `--menu=false` is accepted.
- Non-false provenance/SBOM attestation requests require the customized `stephenlclarke/container` and `container-builder-shim` build path; explicit false forms are accepted as no-op opt-outs.
- Runtime build execution requires the matching `stephenlclarke/container` build backend and SSH-capable builder image.

## Open Blockers

- Released Apple compatibility still depends on upstream acceptance of fork-backed runtime primitives.
- SonarQube status still needs a post-push check; use the `pr-refresh` helper checkout if present, otherwise check the published GitHub/SonarQube result directly.

## Open Follow-ups

- Continue the strict cleanup review around remaining orphan/resource edge cases; missing containers, missing networks, and missing volumes are now covered by tests and live smoke.
- Continue live runtime smoke around progress rendering when touching slow paths. If a local `container compose` run or build appears to hang before any screen output, treat that as a progress regression: reproduce the silent phase, add a focused first-frame test, and emit a Docker Compose-style spinner/status row before the blocking operation begins.

## Next Step

Continue the local review loop on `main`-bound changes: prove the package path locally, then push only once a coherent functionality slice is ready for review.
