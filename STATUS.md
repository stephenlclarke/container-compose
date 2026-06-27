# Status

Last updated: 2026-06-27 11:29 BST.

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
swift test --disable-automatic-resolution --filter 'ComposeProgressTests|ComposeProgressLoadingTests|buildEmitsFirstProgressRowBeforeContainerBuildStarts|buildEmitsProgressRowsWhenProgressIsEnabled|upDirectImagePullEmitsFirstProgressRowBeforePullStarts|upDirectImagePullEmitsProgressBeforeRun|runDirectImagePullEmitsProgressBeforeOneOffContainer|startUsesDirectRuntimeAPIAndDryRunPreservesCommandOutput'
swift test --disable-automatic-resolution --filter 'ComposeProgressTests|interactiveRunEmitsProgressBeforeTerminalHandoff|attachedExecEmitsProgressBeforeTerminalHandoff'
swift test --disable-automatic-resolution --filter 'cpRejectsStdioTarStreamingOperands|cpRejectsEmptyServicePaths|cpMapsServiceReferencesInBothCopyDirections'
swift test --disable-automatic-resolution --filter 'buildUsesCLIWhilePullAndPushUseDirectImageAPI|buildResolvesDockerfileRelativeToBuildContext|runSupportsOneOffContainersAndOptionFlags|upMapsListEntrypointToExecutableAndCommandPrefix|ComposeRuntimeSmokeTests'
swift test --disable-automatic-resolution --filter 'runNoDepsOnlyCreatesSelectedServiceResources|runCreatesProjectResourcesBeforeOneOffContainers|runNoDepsSkipsDependencyMetadataValidation'
swift test --disable-automatic-resolution --filter 'watchAppliesProvidedInitialUpOptions|watchDryRunEmitsValidatedTriggerPlan|watchRebuildsServicesAndPrunesImages|watchRejectsServicesWithoutDevelopTriggers'
swift test --disable-automatic-resolution --filter 'ComposeCLIHelpTests|downServiceSelection|downRemovesProjectResourcesInDependencyOrder|downRemovesAllServiceImagesWhenRequested|downRemovesOnlyLocalBuildImagesWhenRequested'
swift test --disable-automatic-resolution --filter 'ps|ComposeCLIHelp'
CONTAINER_BIN=/Users/sclarke/github/container/bin/container COMPOSE_TEST_BINARY=/Users/sclarke/github/container-compose/.build/debug/compose CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --skip-build --filter ComposeRuntimeSmokeTests
make check
make ci
make cli-smoke-built
swift test --disable-automatic-resolution --filter ComposeCLIHelpTests
swift build --disable-automatic-resolution --product compose
make package-debug PLUGIN_ARCHIVE=/tmp/container-compose-plugin-ci-debug.tar.gz
actionlint .github/workflows/ci.yml .github/workflows/codeql.yml
npx --yes markdownlint-cli README.md PLAN.md STATUS.md docs/upstream/apple-container/copy/ISSUE-copy-stdio-archive-streams.md
npx --yes markdownlint-cli BUILD.md
git diff --check
```

All passed locally after extending progress feedback from project loading and image work into non-interactive runtime create/start/run handoffs, then adding focused first-frame tests for Compose model loading, variable loading, image build, image pull, runtime handoff waits, foreground interactive `run`, and attached `exec`. The progress contract now proves visible stderr feedback is emitted before the normalizer, `container build`, direct image pull, direct runtime start/run operation, or foreground terminal handoff can appear to hang. Foreground interactive process replacement remains unwrapped so shells and attached sessions keep direct terminal control, but `run` and attached `exec` now emit a one-way progress handoff row before the runtime takes terminal ownership. The latest live runtime smoke also proves a real build-backed `run --rm --no-TTY` emits progress before Apple build output, and a service with list-form `entrypoint` plus `command` starts successfully through the local packaged container runtime. That smoke exposed and fixed two compatibility issues: Compose `dockerfile` paths now resolve relative to the build context before invoking `container build`, and list-form entrypoints now map the first element to Apple `--entrypoint` while preserving the remaining entrypoint arguments before the service command. The `compose cp` compatibility work also tightened local-to-local operands, service-side relative paths, and `-` stdin/stdout tar-stream rejection. `compose run --no-deps` now scopes resource creation to the one-off service and any dependency services actually selected, so skipped dependency-only networks and volumes are not prepared before the one-off container starts. `compose down [SERVICES]` now accepts selected services, stops and removes only those containers, applies `--rmi` to selected service images, and avoids tearing down shared project networks or named volumes unless the whole project is being brought down. `compose ps [SERVICE...]` now accepts positional service filters, validates selected service names before runtime discovery, and applies the same selection to table, JSON, template, quiet, and `--services` projections. `compose up --watch` is now wired to the watch engine: its initial start reuses the normal `up` option model, validates selected `develop.watch` triggers, and rejects Docker-incompatible `--watch --detach` and `--watch --wait` combinations. `compose up --detach`, `compose up --wait`, and `compose up --no-start` now accept Docker log-presentation flags `--no-color`, `--no-log-prefix`, and `--timestamps` as harmless no-ops because those modes do not format attached foreground logs; attached `up` still rejects them until foreground log rendering exists. Main CI package validation now builds a debug development artifact rather than re-running the frozen release packaging lane on every active-development push, and the obsolete late release-artifact cache step has been removed from main validation. CodeQL now gates main on the Go normalizer only, using the release Go build path; Swift CodeQL is documented as blocked because the CodeQL Swift compiler trace rebuilds the fork-backed Apple dependency graph and times out before reaching `container-compose` sources. The local `make package-debug` proof produced a `lane: main`, `buildType: debug` archive while still release-building the Go normalizer with `CGO_ENABLED=0`, `-trimpath`, and stripped linker flags. Frozen `release/*` and `snapshot/*` package behavior remains unchanged. The latest full `make ci` with captured counts ran 697 Swift tests, reported Swift coverage at 90.12%, reported Go normalizer coverage at 92.39%, and built the Go normalizer with `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w"`. The current `container` pin includes Apple upstream test and CI fixture updates through `be3b1f2`, plus the Apple `containerization` 0.35 package-version update through `c34d340` while retaining Stephen's `containerization` support branch; compose still builds against the refreshed fork ref.

## Open Blockers

- Released Apple compatibility still depends on upstream acceptance of fork-backed runtime primitives.
- SonarQube status should be checked through `/Users/sclarke/github/pr-refresh` with `make sonar-status` after the next push.

## Open Follow-ups

- Continue the strict cleanup review around remaining orphan/resource edge cases; missing containers, missing networks, and missing volumes are now covered by tests and live smoke.
- Continue live runtime smoke around progress rendering when touching slow paths. If a local `container compose` run or build appears to hang before any screen output, treat that as a progress regression: reproduce the silent phase, add a focused first-frame test, and emit a Docker Compose-style spinner/status row before the blocking operation begins.

## Next Step

Continue the local review loop on `main`-bound changes: prove the package path locally, then push only once a coherent functionality slice is ready for review.
