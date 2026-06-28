# Status

Last updated: 2026-06-28 10:05 BST.

This file is the current-state handoff for `container-compose`. Keep it short. Do not store historical evidence here; use git history, GitHub Actions runs, SonarQube, and the handoff drafts under `docs/upstream/` when old details are needed.

## Current State

The repository uses `main` for active development and release branches for installable package lanes:

| Branch | Lane | Package intent | Runtime dependency |
| --- | --- | --- | --- |
| `main` | Active development | Full CI, CodeQL, SonarQube, and Homebrew main prebuilt packages | `container` main, `containerization` main, and the builder image pinned by `container` |
| `release` | Moving stable release | Optimized Swift package with release-built Go normalizer | `container` release, `containerization` release, and the builder image pinned by `container` |
| `release-VERSION-TAG` | Immutable tagged release copy | Optimized Swift package with release-built Go normalizer | Matching release source refs and the reviewed builder image tag |

Homebrew lanes install prebuilt release-quality assets and should not require Go, Xcode, or a Swift toolchain on the target machine. There is no active debug snapshot formula lane.

## Current Integration Assumption

`container-compose` still depends on fork-backed runtime surfaces for several forward Compose behaviors. Keep each package lane pinned to the matching `stephenlclarke/container` and `stephenlclarke/containerization` surfaces until the equivalent Apple upstream APIs are accepted and the plugin has been updated to those upstream surfaces.

The main drift risks are logs, events, restart policy, health, exit/completion metadata, networking identity, IPAM/DNS, process listing, dynamic ports, copy/archive behavior, build inputs, mounts, secrets/configs, blkio, sysctls, and runtime API shape changes.

Current reviewed main-lane pins:

- `stephenlclarke/container`: `928b9e12506471c926e9cf52d20e65a9bb1c19af`
- `stephenlclarke/containerization`: `a0b08ffeda51ea5396efb0788e060610c39f4b55`
- `ghcr.io/stephenlclarke/container-builder-shim/builder`: `0.13.3`

## Current Docs Shape

The old long-lived evidence files have been removed from the top-level documentation set. Current ownership is:

- [PLAN.md](PLAN.md): roadmap and review gates.
- [STATUS.md](STATUS.md): current branch, blocker, and validation handoff.
- [DESIGN.md](DESIGN.md): architecture and runtime boundary.
- [BUILD.md](BUILD.md): build, test, package, and validation commands.
- [INSTALL.md](INSTALL.md): Homebrew and archive install flow.
- `docs/upstream/`: issue/PR drafts and detailed upstream handoff material.

## Latest Local Validation

The latest local validation passed with focused Swift tests, runtime smoke tests, Go normalizer tests, `make check`, `make ci`, `make cli-smoke-built`, workflow linting, Markdown linting, and `git diff --check`. Detailed command history belongs in git history and CI logs, not this handoff.

Most recent coverage proof:

- Swift: 756 tests, 89.77% line coverage.
- Go normalizer: 92.39% line coverage.

## Recent Functional State

- Progress feedback: project loading, variable loading, image build, image pull, direct runtime create/start/run, foreground interactive `run`, and attached `exec` emit visible stderr progress before slow or terminal-taking operations can look hung.
- Build and image behavior: Compose `dockerfile` paths resolve relative to build context, list-form entrypoints map correctly to Apple `--entrypoint`, `compose build --print` renders deterministic Buildx bake JSON without build/push side effects, disabled provenance/SBOM forms pass through, and `build.ssh` / `--ssh` flow through the build path.
- Core command support: `compose run`, `run --no-deps`, `down [SERVICES]`, `create`, `config`, `ps [SERVICE...]`, `watch`, `up --watch`, `up --attach`, `up --attach-dependencies`, exit-control `up` flags, `exec --privileged`, and lifecycle or watch `privileged: true` are covered by focused tests or runtime smoke.
- Attach and foreground output: `attach --no-stdin` follows selected service logs and supports default signal proxying; `up --no-color`, `up --no-log-prefix`, and `up --timestamps` are supported through the raw foreground or structured log paths.
- Packaging and quality: CodeQL gates the release-built Go normalizer path, Swift CodeQL remains blocked by fork-backed dependency rebuild timeouts, and all Go package outputs are release-built with `CGO_ENABLED=0`, `-trimpath`, and stripped linker flags.

## Current Limits

- Interactive attach with stdin reattach remains blocked until Apple exposes an interactive attach primitive.
- Bare `--menu` / `--menu=true` remain blocked until interactive shortcut handling exists; `--menu=false` is accepted.
- True provenance/SBOM attestation requests remain blocked until the build backend can produce compatible attestations; explicit false forms are accepted.
- Runtime build execution requires the matching `stephenlclarke/container` build backend and SSH-capable builder image.

## Open Blockers

- Released Apple compatibility still depends on upstream acceptance of fork-backed runtime primitives.
- SonarQube status should be checked through `/Users/sclarke/github/pr-refresh` with `make sonar-status` after the next push.

## Open Follow-ups

- Continue the strict cleanup review around remaining orphan/resource edge cases; missing containers, missing networks, and missing volumes are now covered by tests and live smoke.
- Continue live runtime smoke around progress rendering when touching slow paths. If a local `container compose` run or build appears to hang before any screen output, treat that as a progress regression: reproduce the silent phase, add a focused first-frame test, and emit a Docker Compose-style spinner/status row before the blocking operation begins.

## Next Step

Continue the local review loop on `main`-bound changes: prove the package path locally, then push only once a coherent functionality slice is ready for review.
