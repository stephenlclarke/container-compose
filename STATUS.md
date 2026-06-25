# Status

Last updated: 2026-06-25 18:06 BST.

This file is the current-state handoff for `container-compose`. Keep it short. Do not store historical evidence here; use git history, GitHub Actions runs, SonarQube, and the handoff drafts under `docs/upstream/` when old details are needed.

## Current State

The repository uses `main` for active development and frozen branches for installable package lanes:

| Branch | Lane | Package intent | Runtime dependency |
| --- | --- | --- | --- |
| `main` | Active development | Full CI, CodeQL, and SonarQube signal | Pin to the required `stephenlclarke/container` and `stephenlclarke/containerization` surfaces |
| `release/*` | Frozen release | Optimized Swift package with release-built Go normalizer | Pin to the reviewed runtime fork refs for that release branch |
| `snapshot/*` | Frozen debug snapshot | Debug Swift package with release-built Go normalizer | Pin to the reviewed runtime fork refs for that snapshot branch |

Frozen lanes should remain installable through Homebrew without requiring Go, Xcode, or a Swift toolchain on the target machine.

## Current Integration Assumption

`container-compose` still depends on fork-backed runtime surfaces for several forward Compose behaviors. Keep the integration branch pinned to the matching `stephenlclarke/container` and `stephenlclarke/containerization` surfaces until the equivalent Apple upstream APIs are accepted and the plugin has been updated to those upstream surfaces.

The main drift risks are logs, events, restart policy, health, exit/completion metadata, networking identity, IPAM/DNS, process listing, dynamic ports, copy/archive behavior, build inputs, mounts, secrets/configs, blkio, sysctls, and runtime API shape changes.

## Current Docs Shape

The old long-lived evidence files have been removed from the top-level documentation set. Current ownership is:

- [PLAN.md](PLAN.md): roadmap and review gates.
- [STATUS.md](STATUS.md): current branch, blocker, and validation handoff.
- [DESIGN.md](DESIGN.md): architecture and runtime boundary.
- [BUILD.md](BUILD.md): build, test, package, and validation commands.
- [INSTALL.md](INSTALL.md): Homebrew and archive install flow.
- `docs/upstream/`: issue/PR drafts and detailed upstream handoff material.

## Latest Local Validation

Current local validation:

```sh
make go-build
make go-test
make package-debug PLUGIN_ARCHIVE=/tmp/container-compose-plugin-snapshot-debug-arm64.tar.gz
make package-release PLUGIN_ARCHIVE=/tmp/container-compose-plugin-release-arm64.tar.gz CONTAINER_COMPOSE_BRANCH=release/local CONTAINER_COMPOSE_LANE=release
make swift-test
make cli-smoke-built
make ci
npx --yes markdownlint-cli BUILD.md
npx --yes markdownlint-cli README.md BUILD.md PLAN.md STATUS.md
npx --yes markdownlint-cli BUILD.md PLAN.md STATUS.md BRANCHES.md README.md INSTALL.md DESIGN.md
git diff --check
```

All passed locally. `make ci` reported Swift coverage 90.26% and Go coverage 93.26%. The debug and release package targets both built the Go normalizer with `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w"`. Local package inspection confirmed the release archive includes `compose/bin/compose`, `compose/config.toml`, `compose/resources/build-info.json`, and `compose/resources/compose-normalizer`.

## Open Blockers

- Released Apple compatibility still depends on upstream acceptance of fork-backed runtime primitives.
- SonarQube status should be checked through `/Users/sclarke/github/pr-refresh` with `make sonar-status` during the next full maintenance refresh.
- Runtime smoke tests still require a responsive local Apple container runtime; the last enabled local run timed out during `container system status`.

## Next Step

Continue the local review loop on `main`-bound changes: prove the package path locally, then push only once a coherent functionality slice is ready for review.
