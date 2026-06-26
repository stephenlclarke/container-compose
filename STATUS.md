# Status

Last updated: 2026-06-26 22:05 BST.

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

Current reviewed fork pins:

- `stephenlclarke/container`: `834e57248cb6c1efbd28e606c8d03e20ea44e9d1`
- `stephenlclarke/containerization`: `a0b08ffeda51ea5396efb0788e060610c39f4b55`

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
swift test --disable-automatic-resolution --filter 'upDirectImagePullEmitsProgressBeforeRun|upQuietPullSuppressesDirectImagePullProgress|runDirectImagePullEmitsProgressBeforeOneOffContainer|runQuietPullSuppressesDirectImagePullProgress'
make check
make ci
npx --yes markdownlint-cli README.md PLAN.md STATUS.md
git diff --check
```

All passed locally after extending Compose-owned progress reporting to direct image pull preparation for `run` and `up`. `make ci` ran 668 Swift tests, reported Swift coverage at 90.03%, reported Go normalizer coverage at 92.39%, and built the Go normalizer with `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w"`.

## Open Blockers

- Released Apple compatibility still depends on upstream acceptance of fork-backed runtime primitives.
- SonarQube status should be checked through `/Users/sclarke/github/pr-refresh` with `make sonar-status` after the next push.
- Runtime smoke tests still require a responsive local Apple container runtime; the last enabled local run timed out during `container system status`.

## Open Follow-ups

- Verify real `run` and `up` build/startup paths emit immediate terminal progress before the Apple build subprocess produces output, now that normalization, direct image pulls, and image builds use the existing Docker Compose-style `--progress` policies and spinner.

## Next Step

Continue the local review loop on `main`-bound changes: prove the package path locally, then push only once a coherent functionality slice is ready for review.
