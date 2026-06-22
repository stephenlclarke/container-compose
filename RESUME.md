# Resume: Process Listing / Compose Top Slice

<!-- markdownlint-disable MD013 -->

Last updated: 2026-06-22 10:18 BST

This file parks the current cross-repo work so it can be resumed on another MBP. The active feature slice is process listing / `top` support across:

- `stephenlclarke/containerization`
- `stephenlclarke/container`
- `stephenlclarke/container-compose`

Do not push to Apple upstream remotes from this parked state. Continue using the user forks and keep future upstreamable work as small, signed, PR-shaped commits.

## Current Branches And Remotes

### containerization

- Local path: `/Users/sclarke/github/containerization`
- Branch: `integration/blkio-runtime`
- User remote: `origin = https://github.com/stephenlclarke/containerization.git`
- Apple remote: `upstream = https://github.com/apple/containerization.git`
- Pushed status at park time: branch was clean except for untracked local handoff notes under `docs/upstream/process-list/`.

Relevant commits:

- `d69f7e5 feat(runtime): expose container process identifiers`
- `aaa143b fix(runtime): allow paused process listing`

Those commits were pushed to `origin/integration/blkio-runtime`.

### container

- Local path: `/Users/sclarke/github/container`
- Branch: `logs-integration-chris`
- User remote: `fork = https://github.com/stephenlclarke/container.git`
- Apple remote: `origin = https://github.com/apple/container.git`
- Pushed status at park time: branch was clean except for untracked local handoff notes under `docs/upstream/process-list/`.

Relevant commit:

- `14a3067 feat(runtime): expose container process identifiers`

That commit was pushed to `fork/logs-integration-chris`.

### container-compose

- Local path: `/Users/sclarke/github/container-compose`
- Branch: `logs-integration`
- User remote: `origin = https://github.com/stephenlclarke/container-compose.git`
- Pushed status before this resume commit: local branch was ahead of `origin/logs-integration` by one code commit.

Relevant code commit:

- `b44ba55 feat(top): support fork-backed process listing`

Known unrelated local file:

- `/Users/sclarke/github/container-compose/.vscode/settings.json` is untracked and was intentionally left alone.

## Implemented So Far

### containerization runtime layer

The lower runtime now exposes PID-only process identifiers:

- Added a `ContainerProcesses` RPC in `SandboxContext.proto`.
- Regenerated `SandboxContext.grpc.swift` and `SandboxContext.pb.swift`.
- Added `VirtualMachineAgent.containerProcesses(containerID:)`.
- Added `Vminitd.containerProcesses(containerID:)`.
- Added `LinuxContainer.processIdentifiers()`.
- Added `Cgroup2Manager.processIdentifiers()` parsing `cgroup.procs`.
- Added `ManagedContainer.processIdentifiers()`.
- Added `Initd.containerProcesses(...)`.
- Added test coverage in `LinuxContainerTests.processIdentifiersAreReadFromTheAgent`.
- Follow-up fix allows process listing for paused containers as well as started containers.

Validation already run:

```sh
make protos
swift test --filter LinuxContainerTests/processIdentifiersAreReadFromTheAgent
make swift-fmt-check
git diff --check
```

### container API and CLI layer

The public container fork now exposes process identifiers through API, XPC, runtime client, runtime Linux service, and CLI:

- Added `ContainerProcesses` in `ContainerResource`.
- Added `ContainerClient.processes(id:)`.
- Added `XPCKeys.processes` and `XPCRoute.containerProcesses`.
- Added API server route wiring for `harness.processes`.
- Added `ContainersHarness.processes(_:)`.
- Added `ContainersService.processes(id:)`.
- Added `RuntimeKeys.processes` and `RuntimeRoutes.processes`.
- Added `RuntimeClient.processes()`.
- Added runtime Linux helper route and `RuntimeService.processes(_:)`.
- Added `container top <container>` as a PID-only first slice with list-format rendering.
- Added `ContainerProcessesTests`.
- Added `ContainerTopFormattingTests`.
- Updated `Package.resolved` to pin `containerization` at `aaa143b`.

Validation already run:

```sh
swift test --filter ContainerProcessesTests
swift test --filter ContainerTopFormattingTests
swift build --product container
git diff --check
```

### container-compose plugin layer

The plugin now has fork-backed `container compose top [SERVICES...]` support:

- Added `ComposeTableRendering.swift` to share simple padded table rendering.
- Added `ContainerTopAdapter.swift`.
- Added `ComposeTopTarget`.
- Added `ComposeTopRecord`.
- Added `ContainerTopAPIClienting`.
- Added `ContainerTopManaging`.
- Added `ContainerTopAPIClient`.
- Added `ContainerClientTopManager`.
- Added `ComposeTopOptions`.
- Added `ComposeOrchestrator.top(project:options:)`.
- Added `topManager` dependency injection alongside the other runtime managers.
- Replaced the `Top` placeholder in `ComposePlugin.swift` with an async project-backed implementation.
- Updated `Package.resolved` to pin `containerization` at `aaa143b`.
- Added tests for service selection, dry-run rendering, direct API forwarding, dependency injection, and PID table output.

Validation already run:

```sh
swift test --filter ComposeOrchestratorTests/top
swift test --filter ComposeOrchestratorTests/dependencyGroupsPreserveIndividuallyConfiguredCollaborators
swift test --filter ComposeOrchestratorTests/statsManagerRendersStaticTableFromDirectAPIStats
swift build --product compose
make format
git diff --check
```

Important behavior boundary:

- This is PID-only `top` support.
- Docker `top` also exposes richer process metadata such as user, elapsed CPU time, command, and arguments.
- Full Docker parity still needs another `containerization` / `apple/container` slice for richer process metadata.
- Compose service fan-out, service names, and output formatting remain in `container-compose`; do not move them into `apple/container`.

## Handoff Notes Created During Parking

The following files were created locally before parking. The `container-compose` copies are committed with this resume file. The `container` and `containerization` copies were still untracked in their respective repos at park time, so either commit/push them there later or recreate them from this section.

### containerization local handoff files

Local files:

- `/Users/sclarke/github/containerization/docs/upstream/process-list/ISSUE-containerization-process-identifiers.md`
- `/Users/sclarke/github/containerization/docs/upstream/process-list/PR-containerization-process-identifiers.md`

Summary:

- Issue: request a Linux container process-identifier runtime primitive for `container top` and `docker compose top` compatibility.
- PR: expose process identifiers through VM agent, `vminitd`, `LinuxContainer`, cgroup v2 parsing, and tests.
- Commit tracking: `d69f7e5`, `aaa143b`, `14a3067`, `b44ba55`.

### container local handoff files

Local files:

- `/Users/sclarke/github/container/docs/upstream/process-list/ISSUE-container-process-identifiers.md`
- `/Users/sclarke/github/container/docs/upstream/process-list/PR-container-process-identifiers.md`

Summary:

- Issue: request `ContainerClient.processes(id:)` and `container top <container>`.
- PR: add `ContainerProcesses`, API/XPC/runtime routes, runtime Linux service wiring, and CLI table output.
- Commit tracking: `14a3067`, `d69f7e5`, `aaa143b`, `b44ba55`.

### container-compose handoff files

Files included in this repo:

- `docs/upstream/process-list/ISSUE-compose-top-process-list.md`
- `docs/upstream/process-list/PR-compose-top-process-list.md`

Summary:

- Issue: request `container compose top [SERVICES...]`.
- PR: replace the unsupported placeholder with service-container selection plus direct `ContainerClient.processes(id:)` fan-out.
- Commit tracking: `b44ba55`, `14a3067`, `d69f7e5`, `aaa143b`.

Live GitHub check at park time:

```sh
gh issue list --repo apple/container --state open --search 'top process listing process list in:title,body' --limit 20
gh pr list --repo apple/container --state open --search 'top process listing process list in:title,body' --limit 20
gh issue list --repo apple/containerization --state open --search 'process listing process identifiers cgroup.procs top in:title,body' --limit 20
gh pr list --repo apple/containerization --state open --search 'process listing process identifiers cgroup.procs top in:title,body' --limit 20
```

All four searches returned no open matching issues or PRs.

## Work Still Outstanding

1. Update `container-compose` `COMPATIBILITY.md`.

   Current docs still say `top` is blocked. Change that to:

   - fork-backed `container compose top` is supported as a PID-only table through `ContainerClient.processes(id:)`;
   - released upstream `apple/container` still needs an accepted process-listing API;
   - full Docker `top` columns still need richer process metadata.

2. Update `container-compose` `PLAN.md`.

   Add a completed row for the process-listing / `compose top` slice with timestamps around `2026-06-22 10:13 BST`, commit IDs `d69f7e5`, `aaa143b`, `14a3067`, and `b44ba55`, and the note that full Docker process metadata remains a later runtime gap.

3. Decide what to do with the untracked handoff files in `containerization` and `container`.

   Options:

   - commit and push them to the user fork branches; or
   - delete/recreate them when preparing the upstream PRs.

4. Run broader validation if desired before the next feature slice.

   Suggested local commands:

   ```sh
   cd /Users/sclarke/github/container-compose
   make check
   make coverage-check
   swift test
   ```

5. Continue the larger goal after this parked slice.

   The next work should pick one Compose topic and carry it through until implemented or blocked. Candidate topics from the previous direction:

   - runtime data gaps after `top`, especially `events`;
   - richer process metadata for full Docker `top` parity;
   - advanced build configuration;
   - remaining `container-compose` design gaps in the CLI Command Status backlog.

## Commands To Rehydrate On Another MBP

```sh
cd ~/github/containerization
git fetch origin upstream
git switch integration/blkio-runtime
git pull --ff-only origin integration/blkio-runtime

cd ~/github/container
git fetch fork origin
git switch logs-integration-chris
git pull --ff-only fork logs-integration-chris

cd ~/github/container-compose
git fetch origin
git switch logs-integration
git pull --ff-only origin logs-integration
```

Then check the pinned dependencies:

```sh
cd ~/github/container-compose
swift package resolve
swift build --product compose
swift test --filter ComposeOrchestratorTests/top
```

## Slack Context

Progress updates were posted to `xyzzy-tools.slack.com#codex`:

- Start of the process-listing/top slice: `https://xyzzytools.slack.com/archives/C0B1RNM8ZJ5/p1782118908365609`
- Parking handoff update: `https://xyzzytools.slack.com/archives/C0B1RNM8ZJ5/p1782119865100719`

Post another Slack update before resuming code work and after the next code slice.
