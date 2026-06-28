# Status

Last updated: 2026-06-28 05:54 BST.

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

- `stephenlclarke/container`: `39a2ce4ccb6c474d41a6146a6148d445b7fa0554`
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
swift test --disable-automatic-resolution --filter 'runSupportsOneOffContainersAndOptionFlags|runNoDepsOnlyCreatesSelectedServiceResources|runUseAliasesMapsNetworkAliasesToSingleNetworkAttachment|runCommandAndOptionsAreShownAsSupported'
swift test --disable-automatic-resolution --filter 'watchAppliesProvidedInitialUpOptions|watchDryRunEmitsValidatedTriggerPlan|watchRebuildsServicesAndPrunesImages|watchRejectsServicesWithoutDevelopTriggers|watchCommandAndOptionsAreShownAsSupported'
swift test --disable-automatic-resolution --filter 'upRawAttachedOutputFlagsAreShownAsSupported|upRawAttachedOutputFlagsParse|upTimestampsIsShownAsSupported'
.build/debug/compose --ansi never --project-name rawflags --file Tests/ComposeRuntimeTests/Fixtures/ps/compose.yml --dry-run up --no-color --no-log-prefix ps-app
swift test --disable-automatic-resolution --filter 'upTimestampsDetachesForegroundServiceAndFollowsTimestampedLogs|upTimestampsDryRunRendersDetachedRunAndFollowedTimestampedLogs|upTimestampsIsShownAsSupported|upRawAttachedOutputFlagsParse'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeDryRunUpTimestampsFollowsTimestampedLogs
swift test --disable-automatic-resolution --filter 'upAttachFollowsSelectedServiceLogsAfterDetachedStart|upAttachDependenciesFollowsSelectedServiceAndDependencyLogs|upAttachRejectsServicesOutsideSelectedStartGraph|upAttachOptionsAreShownAsSupported|upRawAttachedOutputFlagsParse'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeDryRunUpAttachFollowsSelectedLogs
swift test --disable-automatic-resolution --filter 'upExitCodeFromReturnsSelectedServiceStatusAndTearsDownProject|upExitCodeFromAbortsOnOtherServiceExitAndReturnsSelectedStatus|upAbortOnContainerFailureReturnsFailingStatusAndTearsDownProject|upAbortOnContainerExitReturnsFirstStatusAndTearsDownProject|upExitControlDryRunRendersWaitThenDownPlan|upExitControlRejectsDetachedModeBeforeSideEffects|upExitControlOptionsAreShownAsSupported|upRawAttachedOutputFlagsParse'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeUpExitCodeFromReturnsSelectedStatus
swift test --disable-automatic-resolution --filter 'buildPrintRendersBakeTargetsWithoutBuildSideEffects|buildPrintRendersInlineDockerfile|buildPrintRejectsEmptyBuildArgumentNames|buildPrintOptionIsShownAsSupported|buildPrintFlagParses'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeBuildPrintRendersBakeFileFromComposeFile
swift test --disable-automatic-resolution --filter 'configResolveImageDigestsPinsSelectedServiceImages|configResolveImageDigestsSkipsNonImageProjections|configLockImageDigestsRendersOverrideFile|imageManagerResolvesImageDigestsThroughDirectAPI|configCommandAndDigestOptionsAreShownAsSupported|configImageDigestFlagsParse'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeConfigResolvesImageDigests
swift test --disable-automatic-resolution --filter 'execMapsPrivilegedModeToRuntimeRequests|execMapsEnvironmentUserWorkdirAndDetachOptions|execDryRunRendersDetachedRuntimeCommand|upDetachedRunsPostStartHooksThroughDirectExec|watchSyncsChangedFilesAndRunsSyncExecHooks|detachedExecManagerMapsRequestToDirectProcessAPI|attachedExecManagerMapsRequestToDirectProcessAPI|execCommandAndPrivilegedOptionAreShownAsSupported'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeDryRunExecRendersPrivilegedCommand
swift test --disable-automatic-resolution --filter 'ComposeCLIHelpTests|downServiceSelection|downRemovesProjectResourcesInDependencyOrder|downRemovesAllServiceImagesWhenRequested|downRemovesOnlyLocalBuildImagesWhenRequested'
swift test --disable-automatic-resolution --filter 'ps|ComposeCLIHelp'
CONTAINER_BIN=/opt/homebrew/bin/container COMPOSE_TEST_BINARY=/Users/sclarke/github/container-compose/.build/debug/compose CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --skip-build --filter ComposeRuntimeSmokeTests
CONTAINER_BIN=/opt/homebrew/bin/container COMPOSE_TEST_BINARY=/Users/sclarke/github/container-compose/.build/debug/compose CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --skip-build --filter runtimeRunBuildEmitsProgressBeforeBuildOutput
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

All passed locally after extending progress feedback from project loading and image work into non-interactive runtime create/start/run handoffs, then adding focused first-frame tests for Compose model loading, variable loading, image build, image pull, runtime handoff waits, foreground interactive `run`, and attached `exec`. The progress contract now proves visible stderr feedback is emitted before the normalizer, `container build`, direct image pull, direct runtime start/run operation, or foreground terminal handoff can appear to hang. Foreground interactive process replacement remains unwrapped so shells and attached sessions keep direct terminal control, but `run` and attached `exec` now emit a one-way progress handoff row before the runtime takes terminal ownership. The latest live runtime smoke also proves a real build-backed `run --rm --no-TTY` emits progress before Apple build output, and a service with list-form `entrypoint` plus `command` starts successfully through the local packaged container runtime. That smoke exposed and fixed two compatibility issues: Compose `dockerfile` paths now resolve relative to the build context before invoking `container build`, and list-form entrypoints now map the first element to Apple `--entrypoint` while preserving the remaining entrypoint arguments before the service command. The `compose cp` compatibility work also tightened local-to-local operands, service-side relative paths, and `-` stdin/stdout tar-stream rejection. `compose run --no-deps` now scopes resource creation to the one-off service and any dependency services actually selected, so skipped dependency-only networks and volumes are not prepared before the one-off container starts. `compose run` now reports as supported because every option exposed in help is mapped through the one-off orchestration path and covered by focused unit or runtime smoke tests. `compose down [SERVICES]` now accepts selected services, stops and removes only those containers, applies `--rmi` to selected service images, and avoids tearing down shared project networks or named volumes unless the whole project is being brought down. `compose create` now reports as supported in help because its exposed options are covered by the current implementation and smoke tests. `compose config` now reports as supported because `--resolve-image-digests` and `--lock-image-digests` pin explicit service image tags through registry HEAD resolution without pulling image content. `compose ps [SERVICE...]` now accepts positional service filters, validates selected service names before runtime discovery, applies the same selection to table, JSON, template, quiet, and `--services` projections, and accepts paused container status filters now that the runtime fork exposes paused state. `compose watch` now reports as supported because the watch engine validates `develop.watch` triggers and covers initial sync, sync, sync+restart, sync+exec, restart, rebuild, prune, quiet, and no-up flows. `compose up --watch` is wired to that engine: its initial start reuses the normal `up` option model, validates selected `develop.watch` triggers, and rejects Docker-incompatible `--watch --detach` and `--watch --wait` combinations. `compose build --print` now reports as supported because it renders deterministic Buildx bake JSON for selected build services, expands `--with-dependencies`, merges file and CLI build arguments, maps build secrets and inline Dockerfiles, and exits before `container build` or image push side effects. `compose up --no-color` and `compose up --no-log-prefix` report as supported because attached foreground `up` already emits raw process output without Compose-owned colors or service prefixes. `compose up --timestamps` now reports as supported because attached timestamped mode starts the foreground output service detached, then follows the runtime structured log path with timestamps. `compose up --attach` and `compose up --attach-dependencies` now report as supported because positive attach selection starts the selected graph detached and follows selected service logs through the existing multi-target runtime log stream. `compose up --exit-code-from`, `compose up --abort-on-container-exit`, and `compose up --abort-on-container-failure` now report as supported because exit-control mode starts the selected graph detached, waits through the direct lifecycle API, tears the project down with `down`, and returns the selected or failing service status through the CLI. `compose exec --privileged`, lifecycle hook `privileged: true`, and `develop.watch sync+exec` `privileged: true` now pass a typed privileged process request through the direct exec adapter, and `compose exec` now reports as supported in help. `compose up --detach`, `compose up --wait`, and `compose up --no-start` continue to accept Docker log-presentation flags as harmless no-ops because those modes do not format attached foreground logs. Main CI package validation now builds a debug development artifact rather than re-running the frozen release packaging lane on every active-development push, and the obsolete late release-artifact cache step has been removed from main validation. CodeQL now gates main on the Go normalizer only, using the release Go build path; Swift CodeQL is documented as blocked because the CodeQL Swift compiler trace rebuilds the fork-backed Apple dependency graph and times out before reaching `container-compose` sources. The local `make package-debug` proof produced a `lane: main`, `buildType: debug` archive while still release-building the Go normalizer with `CGO_ENABLED=0`, `-trimpath`, and stripped linker flags. Frozen `release/*` and `snapshot/*` package behavior remains unchanged. The latest `make coverage-check` ran 745 Swift tests, reported Swift coverage at 90.07%, and reported Go normalizer coverage at 92.39%. The current `container` pin is `39a2ce4ccb6c474d41a6146a6148d445b7fa0554`, with Stephen's `containerization` support branch pinned at `a0b08ffeda51ea5396efb0788e060610c39f4b55`.

## Open Blockers

- Released Apple compatibility still depends on upstream acceptance of fork-backed runtime primitives.
- SonarQube status should be checked through `/Users/sclarke/github/pr-refresh` with `make sonar-status` after the next push.

## Open Follow-ups

- Continue the strict cleanup review around remaining orphan/resource edge cases; missing containers, missing networks, and missing volumes are now covered by tests and live smoke.
- Continue live runtime smoke around progress rendering when touching slow paths. If a local `container compose` run or build appears to hang before any screen output, treat that as a progress regression: reproduce the silent phase, add a focused first-frame test, and emit a Docker Compose-style spinner/status row before the blocking operation begins.

## Next Step

Continue the local review loop on `main`-bound changes: prove the package path locally, then push only once a coherent functionality slice is ready for review.
