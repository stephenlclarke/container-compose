# Status

Last updated: 2026-06-25 12:15 BST.

This file is the current-state handoff for `container-compose`. Keep it short. Do not store historical evidence here; use git history, GitHub Actions runs, SonarQube, and the handoff drafts under `docs/upstream/` when old details are needed.

## Current State

The repository has two Homebrew and prebuilt-binary lanes:

| Branch | Lane | Package intent | Runtime dependency |
| --- | --- | --- | --- |
| `main` | Release | Optimized prebuilt Swift and Go binaries | Match `stephenlclarke/container` `main` |
| `develop` | Debug integration | Debug prebuilt Swift and Go binaries | Match `stephenlclarke/container` `develop` |

Both lanes should remain installable through Homebrew without requiring Go, Xcode, or a Swift toolchain on the target machine.

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

Docs-only consolidation validation:

```sh
markdownlint README.md INSTALL.md BUILD.md
markdownlint README.md INSTALL.md BUILD.md PLAN.md STATUS.md CONTRIBUTING.md SUPPORT.md docs/upstream/README.md
markdownlint --disable MD013 MD041 -- $(git diff --name-only -- '*.md' | tr '\n' ' ')
git diff --check
```

All passed locally.

## Open Blockers

- Released Apple compatibility still depends on upstream acceptance of fork-backed runtime primitives.
- CI for the newest pushed commits may still be settling after branch pushes.
- SonarQube status should be checked through `/Users/sclarke/github/pr-refresh` with `make sonar-status` during the next full maintenance refresh.

## Next Step

After this docs consolidation lands, focus on CI signal for the latest `main` and `develop` pushes. If CI is green, the next Apple-review pass should inspect the upstream handoff drafts for stale references rather than keeping additional top-level evidence files.
