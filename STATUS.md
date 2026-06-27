# Status

Last updated: 2026-06-27 02:56 BST.

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

- `stephenlclarke/container`: `ae4667ef6ab2b6099943489e4732f802bea2f3b7`
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
swift test --disable-automatic-resolution --filter 'resourceManagerMapsComposeResourcesToDirectAPIClient|resourceManagerSkipsDeletingMissingVolumes|resourceManagerIgnoresVolumesRemovedAfterPreflight|resourceManagerSurfacesVolumeDeleteFailures|resourceManagerSkipsDeletingMissingNetworks|resourceAPIClientForwardsConfiguredOperations|downSurfacesVolumeRemovalFailures'
swift test --disable-automatic-resolution --filter 'createCreatesResourcesAndServiceContainersWithoutStartingThem|upDirectImagePullEmitsProgressBeforeRun|upQuietPullSuppressesDirectImagePullProgress|startUsesDirectRuntimeAPIAndDryRunPreservesCommandOutput|runDirectImagePullEmitsProgressBeforeOneOffContainer|runQuietPullSuppressesDirectImagePullProgress|ComposeProgressTests'
swift test --disable-automatic-resolution --filter 'cpRejectsStdioTarStreamingOperands|cpRejectsEmptyServicePaths|cpMapsServiceReferencesInBothCopyDirections'
make check
make ci
make cli-smoke-built
swift build --disable-automatic-resolution --product compose
make package-debug PLUGIN_ARCHIVE=/tmp/container-compose-plugin-ci-debug.tar.gz
actionlint .github/workflows/ci.yml .github/workflows/codeql.yml
npx --yes markdownlint-cli README.md PLAN.md STATUS.md docs/upstream/apple-container/copy/ISSUE-copy-stdio-archive-streams.md
npx --yes markdownlint-cli BUILD.md
git diff --check
```

All passed locally after extending progress feedback from project loading and image work into non-interactive runtime create/start/run handoffs, then tightening `compose cp` so local-to-local operands fail with Docker Compose's `unknown copy direction` behavior, local paths containing colons still work when paired with a service target, service-side relative paths such as `api:tmp/file` normalize to container-root paths before reaching the Apple runtime, and `-` stdin/stdout tar-stream operands fail early with a precise Apple copy-stream API gap instead of being treated as literal local filenames. Foreground interactive process replacement remains unwrapped so shells and attached sessions keep direct terminal control. The latest full `make ci` run passed for the `cp -` handoff slice. Main CI package validation now builds a debug development artifact rather than re-running the frozen release packaging lane on every active-development push, and the obsolete late release-artifact cache step has been removed from main validation. CodeQL now has a fingerprinted SwiftPM debug build cache for the manual Swift build step. The local `make package-debug` proof produced a `lane: main`, `buildType: debug` archive while still release-building the Go normalizer with `CGO_ENABLED=0`, `-trimpath`, and stripped linker flags. Frozen `release/*` and `snapshot/*` package behavior remains unchanged. The previous full `make ci` with captured counts ran 676 Swift tests, reported Swift coverage at 89.97%, reported Go normalizer coverage at 92.39%, and built the Go normalizer with `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w"`. The current `container` pin includes Apple upstream test and CI fixture updates through `be3b1f2`, plus the Apple `containerization` 0.35 package-version update through `c34d340` while retaining Stephen's `containerization` support branch; compose still builds against the refreshed fork ref.

## Open Blockers

- Released Apple compatibility still depends on upstream acceptance of fork-backed runtime primitives.
- SonarQube status should be checked through `/Users/sclarke/github/pr-refresh` with `make sonar-status` after the next push.

## Open Follow-ups

- Continue the strict cleanup review around remaining orphan/resource edge cases; missing containers, missing networks, and missing volumes are now covered by tests and live smoke.
- Audit slow startup, normalization, image pull/build, and runtime handoff paths for immediate first-frame progress feedback before subprocesses or runtime calls can appear to hang. In particular, `container-compose` can sit silent for too long when it starts running or building; add Docker Compose-style animated status output, or a compact Swift/Go spinner inspired by Stephen Clarke's [`mac-spinner`](https://github.com/stephenlclarke/mac-sync/blob/main/bin/mac-spinner), before the first expensive call begins.

## Next Step

Continue the local review loop on `main`-bound changes: prove the package path locally, then push only once a coherent functionality slice is ready for review.
