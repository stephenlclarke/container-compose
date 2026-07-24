# Container Stack Critical Review

Date: 2026-07-24

## Executive Verdict

`container-compose` has a broad, unusually well-documented Docker Compose
surface and a strong model-normalisation choice: both this project and Docker
Compose v5.3.1 use `compose-go/v2` v2.13.0. Its current CLI help surface has no
unexpected command or long-option differences from Docker Compose v5.3.1.

It is not yet safe to describe the implementation as complete Docker Compose
parity. Five confirmed Compose defects affect runtime correctness or process
reliability:

1. Library-only image-volume discovery silently returns no declared volumes
   instead of reporting that no runtime is configured.
2. Foundation child processes are not terminated when their owning Swift task
   is cancelled.
3. The package-compatibility preflight can deadlock while waiting for a child
   whose stdout or stderr pipe fills.
4. `compose commit` drops inherited OCI `VOLUME` declarations.
5. Tar-stream `cp` stages through the host filesystem and cannot reliably
   preserve container ownership metadata. Fixing this completely needs the
   direct stream primitive proposed in `apple/containerization`.

The largest engineering risk is now the runtime dependency model, not Compose
file parsing. `ComposeRuntimeSPI` is presented as a clean provider boundary,
but `ComposeCore` still imports and publicly exposes Apple package types. The
three support forks contain 394 non-merge commits beyond current Apple
upstream heads. That gives the project valuable capabilities, but creates a
large review, release, and convergence burden.

The normal CI result also overstates runtime evidence. Twenty-five Swift
runtime smoke tests return immediately when
`CONTAINER_COMPOSE_RUN_RUNTIME_TESTS` is unset, yet are reported as passing.
The configured Swift coverage gate measures only `ComposeCore`; recalculating
the same profile across all first-party Swift targets produces 84.63% line
coverage, with `ComposeContainerRuntime` at 77.46% and `ComposePlugin` at
40.89%.

The recommended order is:

1. Fix the confirmed Compose defects and make test evidence honest.
2. Repair the runtime boundary and reduce support-fork delta.
3. Stabilise signal, log, XPC, and copy behaviour using upstreamable runtime
   fixes.
4. Deliver embedded DNS and network identity, which unlock several visible
   Compose gaps at once.
5. Complete the remaining feasible lifecycle, state, security, storage,
   output-template, build, and model work.

## Audit Baseline

The established primary checkout was not suitable for a destructive refresh:

- `/Users/sclarke/github/container-compose` was on `main`, 276 commits behind
  `origin/main`, with a modified `README.md`.
- The linked
  `/Users/sclarke/github/worktrees/container-compose-template-control-actions`
  worktree contained separate feature work.

Both were preserved. Review and validation used isolated clean worktrees at
the published Compose head and exact dependency pins.

| Repository | Reviewed commit | Baseline |
| --- | --- | --- |
| `stephenlclarke/container-compose` | `42b737dcda830f79b3f0993212e97fefe179f427` | `origin/main`, release `0.10.0` |
| `stephenlclarke/container` | `ea20b242e763eb3e64d412c3dc2bbaa69639d2f4` | Exact `Package.resolved` pin |
| `stephenlclarke/containerization` | `6aa6e803539c59ce754c55628e5417356216b297` | Exact `Package.resolved` pin |
| `stephenlclarke/container-builder-shim` | `f97cddf5b3aae2426a094613793c11c41b1d2e53` | Exact `Tools/release/stack-refs.json` pin |
| `docker/compose` | `f32009d4a2c687dd405398cc7975d12dccaf8dff` | Tag `v5.3.1` |

Current Apple heads at the final source review were:

| Repository | Apple `main` |
| --- | --- |
| `apple/container` | `d1d763530df3c6a326dbae7f0c0a59a335808045` |
| `apple/containerization` | `450d44ecb6d690b7a50250b87d4a40e467d805b8` |
| `apple/container-builder-shim` | `267b5ab98e1d7db7d98af98bdc90578bf5fd3192` |

All repositories were fetched with `git fetch --all --prune --no-tags`.
The review covered:

- all tracked first-party source and test inventories;
- package dependencies, public type boundaries, process execution, archive
  handling, image metadata, lifecycle, networking, logging, events, resources,
  build transport, and runtime adapters;
- every current parity/status marker and all 60 executable parity probes;
- support-fork commit and file-level divergence from current Apple heads;
- all open Apple issue and pull-request metadata, with detailed review of work
  that affects this stack;
- all current `apple/container` discussion metadata, with detailed review of
  relevant architecture and functionality topics;
- Docker Compose v5.3.1 source and live help as the parity oracle.

This was a systematic whole-tree audit with targeted deep review of
parity-critical paths. It is not a formal proof that every line is
defect-free.

## Confirmed Findings

### P1: `ComposeCore` Is Not Runtime-Neutral

The documented architecture says the orchestrator references only
`ComposeRuntimeSPI` and that Apple types belong in the provider:

- `DESIGN.md:93-109`
- `Sources/ComposeCore/ComposeCore.docc/Architecture.md:3-24`
- `docs/upstream/COMPOSE-COUPLING-AUDIT.md`

The package and source do not meet that contract:

- `Package.swift:62-71` gives `ComposeCore` direct dependencies on
  `ContainerAPIClient`, `ContainerResource`, `ContainerizationArchive`,
  `Containerization`, `ContainerizationExtras`, and `ContainerizationOCI`.
- Many `ComposeCore` files import those packages directly, including
  `ComposeOrchestratorRuntimeSupport.swift`,
  `ComposeOrchestratorRunCopyStart.swift`, and
  `ComposeCommitImageArchive.swift`.
- `ContainerServiceCreateAdapter.swift` exposes Apple runtime types from the
  core target.
- Core tests import Apple products and use Apple-shaped doubles, so the test
  architecture reinforces the coupling.

Impact:

- an alternate provider cannot consume `ComposeCore` without the complete
  Apple dependency graph;
- dependency upgrades have a larger blast radius than the design claims;
- Compose policy and Apple DTO translation can drift together;
- the coupling audit currently records a conclusion that the build graph
  disproves.

Ownership: Compose architecture.

Required correction:

- move Apple DTO translation, archive integration, and live API types into
  `ComposeContainerRuntime`;
- keep only runtime-neutral requests and summaries in `ComposeRuntimeSPI`;
- add a package-graph test that fails if `ComposeCore` gains an Apple package
  dependency or `import Container*`;
- update the design and coupling audit only after the package graph proves the
  boundary.

The direction aligns with
[apple/container discussion #1759](https://github.com/apple/container/discussions/1759),
which asks for a dependency-minimal client SDK because Apple API types
currently pull a large implementation graph into front ends.

### P1: Unconfigured Image-Volume Discovery Fails Open

`Sources/ComposeCore/ComposeUnconfiguredRuntime.swift:148-178` makes nearly
every runtime operation throw a clear unavailable error. The exception is
`imageDeclaredVolumeTargets`, which returns an empty array at lines 164-166.

The SPI already has the correct default:
`Sources/ComposeRuntimeSPI/ComposeRuntimeImages.swift:254-256` calls
`imageMetadata` and therefore propagates an unavailable-runtime error.
`ComposeOrchestratorImageVolumes.swift:70` treats the empty array as
authoritative and silently skips image-declared anonymous volumes and copy-up.

Impact: a library consumer can receive an apparently valid plan with missing
Dockerfile `VOLUME` semantics instead of a configuration failure.

Ownership: Compose.

Required correction:

- delete the fail-open override or make it throw the same unavailable error as
  the other image operations;
- add a contract test for every unconfigured SPI method, not only
  `imageExists`;
- add a service fixture whose image has a declared volume and prove the
  library-only path fails explicitly.

### P1: Child Processes Survive Swift Task Cancellation

`Sources/ComposeCore/ProcessRunner.swift:137-263` wraps three Foundation
`Process` modes in checked continuations. None uses a task cancellation
handler, and no cancellation path terminates the child.

Impact:

- cancelling a build, pull, push, normaliser, or helper task can leave its
  process running;
- failure of one task-group member does not promptly stop sibling processes;
- Ctrl-C can appear to hang while orphaned children retain pipes or locks;
- a later command can observe side effects from work the caller believes was
  cancelled.

`Tests/ComposeCoreTests/ProcessRunnerTests.swift` covers launch errors and
large output, but not cancellation or child-process exit.

Ownership: Compose.

Required correction:

- introduce cancellation-aware process state;
- send termination on cancellation, wait for a bounded grace period, then
  kill if required;
- make continuation completion single-owner and race-safe;
- test captured, inherited, and input-bearing modes by recording the child PID
  and proving it exits after cancellation.

### P1: Compatibility Preflight Can Deadlock on Full Pipes

`Sources/ComposePlugin/ContainerPackageCompatibility.swift:260-280` attaches
stdout and stderr pipes, calls `waitUntilExit()`, and only then drains either
pipe.

A child that writes more than the pipe buffer can block before exit, while the
parent waits for exit. This preflight runs before runtime-backed commands, so a
diagnostic or changed `container system version` implementation can deadlock
the whole plugin.

Ownership: Compose plugin.

Required correction:

- drain both streams concurrently while the process runs, preferably through
  the corrected shared process runner;
- add a fake `container` executable that writes more than 256 KiB to each
  stream and prove success and failure paths terminate;
- propagate cancellation and retain bounded diagnostic output.

### P1: `compose commit` Drops Inherited OCI Volumes

`Sources/ComposeCore/ComposeCommitImageArchive.swift:217-235` reconstructs an
image config from the base image and service. It preserves user, environment,
entrypoint, command, working directory, labels, ports, stop signal, and
healthcheck, but unconditionally sets `volumes = nil`.

`ComposeImageMetadata` already contains `declaredVolumeTargets`
(`Sources/ComposeRuntimeSPI/ComposeRuntimeImages.swift:49-88`), so the data is
available. Docker Compose delegates commit to the engine's container commit
operation and retains the effective container config.

The current parity probe uses `alpine:3.20`, which has no declared volume, and
checks other metadata. It therefore cannot catch this defect.

Impact: an image produced by `compose commit` can lose storage semantics from
its base image even though `STATUS.md` marks the command fully supported.

Ownership: Compose.

Required correction:

- seed the output volume map from `base.declaredVolumeTargets`;
- apply additive and replacement `--change VOLUME` behaviour according to the
  Docker commit parser;
- add unit tests for inherited, added, and multiple volumes;
- add a live parity fixture based on an image with a `VOLUME` instruction;
- mark `commit` partial until the regression test passes.

### P1: Tar-Stream `cp` Cannot Preserve Full Container Metadata

`Sources/ComposeCore/ComposeRuntimeArchiveCopying.swift:22-89` implements
streaming input by writing a host tar, extracting it into a host directory,
then path-copying each member into the container. Output reverses the same
path-based staging.

This is content streaming, not tar-stream parity:

- a non-root host process cannot reliably materialise arbitrary container
  UID/GID values;
- host filesystem semantics can alter ownership, mode, links, timestamps, and
  long paths before the runtime sees the data;
- `--archive` cannot guarantee Docker's ownership-preservation contract;
- the parity probe checks data flow, not metadata fidelity.

[apple/containerization PR #812](https://github.com/apple/containerization/pull/812)
adds direct `FileHandle` copy-in/copy-out specifically to preserve tar headers
and path fidelity. It was open as a draft with merge state `BLOCKED` on
2026-07-24. The corresponding
[apple/container PR #1947](https://github.com/apple/container/pull/1947) was
also a blocked draft.

Ownership: lower-runtime primitive first, then Compose adapter.

Required correction:

- mark stdin/stdout archive and `--archive` metadata parity partial now;
- adopt a direct stream API after the lower-runtime contract is accepted;
- keep path traversal and link-target validation at the stream boundary;
- add uid, gid, mode, symlink, hard-link, timestamp, sparse file, long path,
  and large-stream parity fixtures.

### P2: Runtime Test and Coverage Evidence Is Misleading

All 25 tests in
`Tests/ComposeRuntimeTests/ComposeRuntimeSmokeTests.swift` begin with
`guard runtimeTestsEnabled else { return }`. The environment check is at
lines 1622-1623. `make ci` does not set the variable, so Swift Testing reports
all 25 as passing in milliseconds without executing a runtime assertion.

The live lane in `Makefile:245-259` does set the variable, but that lane is
separate from ordinary CI. The distinction is not visible in the normal test
summary.

The coverage gate at `Makefile:293-299` exports only
`--sources Sources/ComposeCore`. Recalculated from the same profile:

| Target | Line coverage |
| --- | ---: |
| All first-party Swift | 84.63% |
| `ComposeCore` | 91.45% |
| `ComposeRuntimeSPI` | 99.06% |
| `ComposeContainerRuntime` | 77.46% |
| `ComposePlugin` | 40.89% |

Several parity-critical live adapters were effectively uncovered:

- `ContainerExecLiveAdapter.swift`: 0%
- `ContainerLifecycleLiveAdapter.swift`: 0%
- `ContainerImageLiveAdapter.swift`: 1.46%

Ownership: Compose test infrastructure.

Required correction:

- use explicit test skipping with a reason, rather than early return;
- make CI print executed and skipped runtime-test counts;
- rename the existing metric to `ComposeCore coverage`;
- add separate gates for SPI, provider, plugin, and aggregate first-party
  coverage;
- prioritise behavioural tests for live adapters, cancellation, signal
  forwarding, log tails, copy streams, and provider preflight.

### P2: Builder Prefetch Stress Tests Pass Broken Expectations

The builder test suite and race suite passed, but two test patterns make that
evidence weaker than the green result suggests:

- `pkg/prefetch/prefetch_test.go:297-300` says caching should produce fewer
  underlying reads than readers, but uses `t.Logf` when the expectation fails.
  The normal run observed 16 reads for 10 readers; the race run observed 19.
- `pkg/prefetch/stress_test.go:100-123` accepts a timeout as expected and can
  pass with 0 of 100 operations complete and 100 errors.
- `pkg/prefetch/stress_test.go:225-232` also treats high-concurrency timeout as
  informational without a minimum completion or error threshold.

Impact: regressions in cache coalescing, liveness, or throughput can remain
green.

Ownership: `container-builder-shim`.

Required correction:

- decide whether read coalescing is a contract; use `t.Errorf` if it is, or
  remove the false expectation if it is not;
- require a deterministic minimum completion count and zero unexpected
  errors;
- separate bounded liveness tests from benchmarks and soak tests;
- retain `go test -race` as a release gate.

### P2: Lifecycle Diagnostics Misassign Existing Gaps

`Sources/ComposeCore/ComposeOrchestratorValidation.swift:295-296` says
`pre_start` needs a new Apple ephemeral-container primitive. The current
runtime gap ledger correctly says the pinned fork already has the required
volumes-from, network, attach, wait, and log primitives; orchestration is
missing in Compose.

Lines 319-321 similarly say interactive lifecycle hooks need Apple stdio
reattach support, although the pinned runtime already supplies it. Stock Apple
still lacks the primitive, but that is not the cause in the supported fork
lane.

Impact: users and maintainers are sent to the wrong repository, and work may
be duplicated in Apple forks.

Ownership: Compose.

Required correction:

- change supported-lane diagnostics to identify missing Compose orchestration;
- reserve stock-Apple diagnostics for version/capability negotiation;
- add tests that assert owner, dependency, and remediation text.

### P3: Temporary Copy and Commit Data Needs Explicit Permissions

Archive-copy and commit paths create temporary directories and files with
Foundation defaults, normally 0755 and 0644. The standard macOS temporary
parent is user-private, which limits exposure under normal operation, but a
caller-controlled `TMPDIR` can point at a shared tree.

Impact: copied container content or image metadata can become readable by
other local users in a non-standard temporary directory.

Ownership: Compose hardening.

Required correction:

- create temporary directories as 0700 and files as 0600;
- verify permissions before writing sensitive data;
- keep cleanup in `defer` and add failure-path tests.

## Design and Maintainability Review

### Strong Patterns

- **Structured normalisation:** delegating interpolation, include, merge, and
  schema projection to `compose-go` is the correct choice. Both products use
  v2.13.0, eliminating a current source of model-version drift.
- **Explicit parity oracle:** Docker Compose v5.3.1 is pinned by source commit
  and checked as a live executable.
- **Protocol-based collaborators:** most orchestration paths have injectable
  managers and deterministic doubles.
- **Plan before side effects:** many commands validate and prepare work before
  touching the runtime.
- **Separate live lane:** runtime and Docker parity are isolated from fast
  source/unit CI, which is sound when skip evidence is explicit.
- **Capability ledger:** `STATUS.md` is unusually comprehensive and already
  distinguishes feasible macOS work from Windows and Swarm behaviour.
- **Upstream boundary policy:** `docs/upstream/README.md` correctly states that
  Compose policy belongs here and generic runtime primitives belong in Apple
  projects. Apple maintainer feedback on
  [apple/container PR #1769](https://github.com/apple/container/pull/1769)
  supports that division.

### Structural Problems

- **The provider boundary is aspirational:** the package graph contradicts
  `DESIGN.md`.
- **The core target owns too much translation:** Apple DTOs, archive types,
  runtime policy, and Compose policy are mixed.
- **The main orchestrator test is too large:**
  `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` is 32,133 lines.
  Broad coverage is valuable, but this file makes ownership, fixtures, failure
  localisation, and parallel test execution harder.
- **Live adapters are under-tested:** one 325-line provider test file covers a
  17-file `ComposeContainerRuntime` target.
- **Fork delta is no longer minimal:** all Apple upstream commits are present,
  but the retained layers are large enough to obscure whether a bug belongs
  upstream, in a fork-only primitive, or in Compose.
- **The upstream handoff registry is too large:** `docs/upstream` contains 581
  Markdown files and 31,431 lines, within a repository of 947 tracked files.
  The current review document was already missing newly reported high-impact
  Apple bugs. A registry this large is difficult to keep current manually.

### Recommended Target Architecture

1. `ComposeModel`: normalised Compose values and deterministic policy with no
   Apple imports.
2. `ComposeRuntimeSPI`: stable runtime-neutral requests, capabilities,
   summaries, streams, and errors.
3. `ComposeCore`: command planning and orchestration against only the SPI.
4. `ComposeContainerRuntime`: all Apple DTO translation, XPC/API clients,
   archive implementation, and capability negotiation.
5. `ComposePlugin`: CLI parsing, compatibility preflight, progress, and
   process-level concerns.
6. `compose-go-normalizer`: schema oracle, versioned independently but pinned
   to the Docker Compose reference.

Enforce the layering in `Package.swift`, source imports, and CI. Do not add an
interception or compatibility framework around private Apple behaviour.

## Fork Divergence

The support forks contain current Apple `main`, so there is no upstream-behind
debt at this snapshot. The fork-only surface is nevertheless large:

| Fork | Behind Apple | Ahead of Apple | Non-merge ahead | Diff from Apple |
| --- | ---: | ---: | ---: | --- |
| `container` | 0 | 281 | 256 | 329 files, +30,184/-1,147 |
| `containerization` | 0 | 126 | 110 | 110 files, +8,547/-505 |
| `container-builder-shim` | 0 | 33 | 28 | 60 files, +2,533/-881 |

This should be managed as an upstream-convergence programme:

- split generic bug fixes and primitives into independently reviewable commits;
- submit or align them with existing Apple proposals;
- delete local ports once equivalent Apple commits land;
- keep Docker-shaped parsing, formatting, orchestration, and aliases in
  `container-compose`;
- maintain a generated capability manifest so Compose can fail accurately
  against stock Apple and matched support versions;
- set a release criterion that every retained fork-only commit has one owner,
  one reason, focused tests, and a current upstream disposition.

## Parity Gap and Ownership Matrix

### Compose-Owned Gaps That Can Start Now

| Area | Gap |
| --- | --- |
| Correctness | Unconfigured image volumes fail open; commit loses inherited volumes |
| Process control | Task cancellation does not terminate children; compatibility preflight can deadlock |
| Lifecycle | `pre_start`; interactive foreground `run` hooks using the already pinned reattach primitive |
| Output | Go-template control actions, nested object traversal, map/range traversal for `ps`, `stats`, and `volumes` |
| Deploy | Accept and preserve local-mode Deploy metadata that Docker Compose accepts but does not schedule |
| Testing | Honest runtime skips; provider/plugin/aggregate coverage; metadata-complete commit and copy fixtures |
| Diagnostics | Supported-lane messages currently blame missing Apple primitives that exist in the pins |
| Security | Explicit private permissions for temporary copy, commit, and secret material |
| Documentation | Correct overclaims for `commit`, tar-stream `cp`, runtime CI, and the SPI boundary |

### Missing from Stock Apple but Present in the Pinned Forks

These are not Compose implementation gaps in the supported lane. They are
upstream convergence and release-channel gaps:

- interactive init-process stream reattachment and attach support;
- event streaming and several Docker-shaped event attributes;
- healthcheck metadata, probes, status, and dependency gating;
- persisted exit codes and process metadata;
- image-declared volume discovery and copy-up support;
- expanded cgroup, namespace, mount, IPAM, device, GPU, and resource controls;
- live snapshot/export and commit support;
- build SSH, attestations, external Dockerfiles, additional contexts, checks,
  named builders, and BuildKit transport extensions;
- copy, label, resolver, XPC descriptor, registry retry, and startup-race bug
  fixes already carried locally.

Each capability should stay in the fork only until an Apple-native equivalent
is merged and consumed.

### Missing or Incomplete in Both Apple Upstream and the Supported Stack

| Area | Required runtime work | Required Compose work |
| --- | --- | --- |
| Network identity | Container-facing, network-scoped DNS listener; alias registration; durable multi-container sandbox for shared namespaces | Service/container names, aliases, `--use-aliases`, complete links, dynamic address reconciliation |
| Network drivers/IPAM | Custom drivers, custom IPAM, multiple same-family pools, disabled IPv4, IPv6 ranges/auxiliary addresses | Validation and projection after typed primitives exist |
| Security | Seccomp/AppArmor profiles, custom user mappings, complete privileged/device isolation | Parse/map profiles and capability diagnostics |
| Resources | CPU realtime, swappiness, OOM-kill disable, richer machine stats | Map fields and expose accurate `stats` |
| Storage | Non-local volume plugins, recursive bind and cache modes, direct tar streams | Driver/options behaviour, archive fidelity, parity tests |
| Docker API | Authenticated Docker-compatible socket proxy boundary | `use_api_socket` |
| Devices/GPU | Vendor GPU/CDI, multiple GPUs, arbitrary passthrough | Reservation and selector mapping |
| Logging | Distinct local/json-file semantics, fan-out resilience, remote/plugin drivers and buffering | Driver options, mode, buffer controls, output parity |
| State/events | `dead`, `restarting`, `removing`; oom, rename, resize, update, attach/detach and explicit restart actions | Rendering, filtering, and state transitions |
| Models | Model runner lifecycle and endpoint API | Start models and inject endpoint/model variables |
| Build | Custom BuildKit frontend and efficient JSON context transfer | Expose supported frontend/context controls and parity fixtures |

### Platform or Product Non-Goals

Do not count these as defects in local macOS Compose unless product scope
changes:

- Windows-only `cpu_count`, `cpu_percent`, `isolation`, `credential_spec`, and
  `npipe`;
- Docker Swarm placement, rolling update, rollback, job scheduling, overlay,
  cluster, and CSI semantics;
- SELinux host relabelling on macOS;
- NVIDIA/CUDA compatibility without a viable macOS/Linux guest runtime;
- a byte-for-byte Docker Engine API implementation as a shortcut around typed
  Apple primitives.

## Apple Upstream Review

At review time:

- `apple/container` had 296 open issues, 168 open pull requests, and 145
  discussions;
- `apple/containerization` had 32 open issues and 29 open pull requests;
- `apple/container-builder-shim` had 4 open issues and 3 open pull requests.

All titles and current states were enumerated. The following work materially
affects this stack.

### Adopt or Port After Review

| Upstream work | Current disposition |
| --- | --- |
| [container #1997](https://github.com/apple/container/pull/1997) | Signal payload is sent as a string, fixing the pinned `ClientProcess.kill` mismatch. Open, non-draft, merge state `BLOCKED`. Required for reliable Compose signal proxying. |
| [container #2000](https://github.com/apple/container/pull/2000) | Fixes `logs -n N` truncation at backward-read chunk boundaries. Open, non-draft, `BLOCKED`. Add Compose tail parity after adoption. |
| [containerization #799](https://github.com/apple/containerization/pull/799) | Fixes missing-source copy deadlock. The fork already carries equivalent behaviour. Replace the local port when Apple merges it. |
| [containerization #813](https://github.com/apple/containerization/pull/813) | Redacts environment values in debug logs. The fork already carries an equivalent fix. Open, non-draft, `BLOCKED`. |
| [containerization #812](https://github.com/apple/containerization/pull/812) and [container #1947](https://github.com/apple/container/pull/1947) | Direct tar-stream copy. Both are draft/blocked and need API, metadata, cancellation, and backpressure review before adoption. |
| [builder-shim #83](https://github.com/apple/container-builder-shim/pull/83) | Custom BuildKit frontends. Open, non-draft, `BLOCKED`. Prefer upstream over a Compose-side parser. |
| [builder-shim #84](https://github.com/apple/container-builder-shim/pull/84) | JSON build-context transfer for performance. Open, non-draft, `BLOCKED`. Benchmark and harden before enabling. |
| [builder-shim #87](https://github.com/apple/container-builder-shim/pull/87) | Correct `.dockerignore` parent re-inclusion. Equivalent commit `2778407` is already in the fork. |

### Current Runtime Bugs That Affect Compose

The relevant reports are also visible in the exact pinned source:

- `container/Sources/Services/ContainerAPIService/Client/ClientProcess.swift:81-85`
  writes the signal as `Int64`, while the runtime route expects the string form
  described by #1941/#1997.
- `container/Sources/ContainerCommands/LogFileOutput.swift:101-129` reads
  backwards in 1,024-byte chunks with the boundary condition reported in
  #1967/#2000.
- `container/Sources/Services/RuntimeLinux/Server/RuntimeService.swift:1899-1920`
  stops `MultiWriter.write` on the first writer error, matching #2009.

| Report | Stack impact |
| --- | --- |
| [container #1941](https://github.com/apple/container/issues/1941) | Signal payload mismatch can break foreground stop/kill and Ctrl-C forwarding. |
| [container #1967](https://github.com/apple/container/issues/1967) | Log tails can truncate the oldest returned line. |
| [container #2009](https://github.com/apple/container/issues/2009) | `MultiWriter` stops fan-out after the first dead attached client returns `EPIPE`, so persisted logs can stop permanently. No reviewed fix was available. |
| [container #2007](https://github.com/apple/container/issues/2007) | Delayed XPC replies can cause checked-continuation misuse and process crash. |
| [container #2008](https://github.com/apple/container/issues/2008) | `container system start` can hide launchd bootstrap failure and report a misleading XPC error in CI/non-login sessions. |
| [container #2003](https://github.com/apple/container/issues/2003) | Runtime startup remains susceptible to reported intermittent failure. |
| [container #1916](https://github.com/apple/container/issues/1916) | Exec/stop hangs overlap Compose lifecycle cancellation and timeout behaviour. |
| [container #1917](https://github.com/apple/container/issues/1917) | Resolver search-domain pollution is fixed in the support fork and should converge upstream. |
| [container #1927](https://github.com/apple/container/issues/1927) | Missing copy source can poison later lifecycle operations; fixed locally and proposed in lower-runtime PR #799. |
| [containerization #804](https://github.com/apple/containerization/issues/804) | VM/resource leak reports affect repeated Compose project lifecycle. |

### Functionality to Track

| Area | Upstream references | Assessment |
| --- | --- | --- |
| DNS and aliases | [container #1809](https://github.com/apple/container/issues/1809), [#1839](https://github.com/apple/container/issues/1839), [PR #1813](https://github.com/apple/container/pull/1813), [PR #1815](https://github.com/apple/container/pull/1815) | Highest-leverage parity dependency. Current groundwork does not yet provide a usable container-facing listener. |
| Shared networking | [containerization #436](https://github.com/apple/containerization/issues/436), [#457](https://github.com/apple/containerization/issues/457), [PR #709](https://github.com/apple/containerization/pull/709) | Needed for richer local networks and, eventually, service/container namespace sharing. PR #709 was `DIRTY`. |
| Seccomp | [container #1915](https://github.com/apple/container/issues/1915), [containerization PR #593](https://github.com/apple/containerization/pull/593) | Generic runtime owner. PR #593 was `DIRTY`; do not reimplement policy in Compose. |
| Machine stats | [container #1919](https://github.com/apple/container/issues/1919), [#1921](https://github.com/apple/container/issues/1921) | Needed for more accurate memory and runtime statistics. |
| Runtime plugins/API | [container #1923](https://github.com/apple/container/issues/1923), [#1925](https://github.com/apple/container/issues/1925) | Potential long-term route to stable provider capabilities and external tooling. Avoid depending on private storage or XPC details. |
| Nested bind mounts | [container #1890](https://github.com/apple/container/issues/1890) | Required for difficult bind/subpath parity cases. |
| Remote volumes | [container #1911](https://github.com/apple/container/issues/1911) | Runtime prerequisite for SMB/NFS or non-local driver behaviour. |
| Build contexts | [container #1930](https://github.com/apple/container/issues/1930) | The support fork implements named/additional contexts; converge on Apple when available. |
| Build image ID file | [container #1998](https://github.com/apple/container/issues/1998) | Useful, bounded build feature. Implement in the runtime first, then expose only if Docker Compose requires it. |
| Storage reclamation | [containerization #414](https://github.com/apple/containerization/issues/414) | Relevant to long-running Compose development environments and snapshot accumulation. |
| Linux pods/hotplug | [containerization #735](https://github.com/apple/containerization/issues/735), [#736](https://github.com/apple/containerization/issues/736), [#767](https://github.com/apple/containerization/issues/767) | Promising basis for shared PID/IPC and sidecars, but not production-ready network-isolated multi-container sandbox semantics. |

### Useful Discussions

| Discussion | Useful direction |
| --- | --- |
| [Compose support #194](https://github.com/apple/container/discussions/194) | Confirms strong demand and concern about fragmented third-party implementations. Apple has not committed to a first-party full Compose implementation. |
| [Plugin expansion #1410](https://github.com/apple/container/discussions/1410) | Highlights plugin/API version mismatch and argues for a shared stable client surface. |
| [Lightweight API client #1759](https://github.com/apple/container/discussions/1759) | Directly supports extracting a minimal SDK and enforcing the Compose runtime boundary. |
| [Snapshot storage #1950](https://github.com/apple/container/discussions/1950) | Motivates visible disk usage, pruning, and `down`/system cleanup work. |
| [Network interface strategy #1939](https://github.com/apple/container/discussions/1939) | Relevant to clearer network capability errors and interface selection. |
| [Networking and DNS #703](https://github.com/apple/container/discussions/703) | Reinforces embedded DNS and network-management demand. |
| [Host network and IPv6 #955](https://github.com/apple/container/discussions/955) | Useful for documenting macOS host-network limits and IPv6 expectations. |
| [Sidecars/shared kernel #779](https://github.com/apple/container/discussions/779) and [LinuxPod/init #842](https://github.com/apple/container/discussions/842) | Potential future primitive for namespace sharing, but only with independent network lifecycle and durable production API. |
| [Configuration #1336](https://github.com/apple/container/discussions/1336) | Supports typed TOML/plugin defaults rather than hidden environment coupling. |
| [Dev Containers #912](https://github.com/apple/container/discussions/912) | Shows attach alone is insufficient; stable API/CLI compatibility remains the ecosystem blocker. |

### Work Not to Use as the Convergence Target

[apple/container PR #1736](https://github.com/apple/container/pull/1736) is a
separate Python Compose prototype with a substantially smaller command and
runtime surface. It is useful as evidence of demand, but merging two
independent orchestration implementations would increase fragmentation. The
preferred boundary is the one endorsed in the discussion around
`apple/container` PR #1769: upstream generic Apple-native primitives, while
Docker and Compose policy remains in this repository.

## Phased Work Items

Priority definitions:

- **P1:** correctness, hang, data/metadata loss, security, or release-evidence
  blocker;
- **P2:** material parity, architecture, maintainability, or reliability gap;
- **P3:** useful extension, performance, or lower-risk hardening.

### Phase 0: Correctness and Honest Evidence

Goal: stop overstating supported behaviour and remove defects that do not need
new Apple design work.

| ID | Priority | Owner | Work item | Acceptance |
| --- | --- | --- | --- | --- |
| CC-001 | P1 | Compose | Make unconfigured image-volume lookup fail closed | Every unconfigured SPI method has a contract test; declared-volume planning reports a clear provider error |
| CC-002 | P1 | Compose | Add task-cancellation ownership to `ProcessRunner` | Cancelled captured/inherited/input child exits within bound; no continuation double-resume; no surviving PID |
| CC-003 | P1 | Plugin | Replace wait-before-drain compatibility preflight | Fake command writes >256 KiB to stdout and stderr without deadlock; cancellation and error text tested |
| CC-004 | P1 | Compose | Preserve inherited volumes during `commit` | Unit and live Docker parity cover inherited/additive/multiple `VOLUME`; status claim restored only after passing |
| CC-005 | P1 | Compose/docs | Downgrade tar-stream `cp` parity pending direct runtime streams | Status and help describe content support versus metadata limits; metadata fixture fails for the expected tracked reason |
| CC-006 | P2 | Compose | Correct lifecycle ownership diagnostics | Pinned-lane errors name Compose orchestration; stock-lane errors name missing Apple capability |
| TEST-007 | P1 | Compose CI | Make live test skips explicit and gate aggregate coverage | CI reports executed/skipped counts; separate Core/SPI/provider/plugin/aggregate thresholds |
| TEST-008 | P2 | Compose | Split the 32k-line orchestrator test by command/capability | Shared fixtures have one owner; tests run in parallel; no coverage loss |
| SEC-009 | P2 | Compose | Set 0700/0600 permissions on sensitive temporary paths | Permission tests cover standard and shared `TMPDIR`; cleanup survives failure |
| DOC-010 | P1 | Compose | Correct `DESIGN.md`, coupling audit, and `STATUS.md` claims | Documentation matches the actual package graph and tested command semantics |
| APPLE-011 | P1 | Runtime forks | Review/port signal and log-tail fixes #1997/#2000 if they remain unmerged | Focused runtime tests and Compose kill/log-tail parity pass; local commits remain independently removable |
| APPLE-012 | P1 | Runtime forks | Fix log fan-out after dead client (#2009) | One failed writer is removed or isolated; persisted log and healthy attach writer continue; no busy loop |

Phase gate:

- `make ci` passes with honest runtime skip reporting;
- aggregate first-party coverage is visible;
- targeted cancellation, preflight, commit-volume, and temp-permission tests
  pass;
- commands no longer claim complete behaviour where a confirmed defect exists.

### Phase 1: Runtime Boundary and Fork Convergence

Goal: make ownership enforceable and reduce the cost of every later feature.

| ID | Priority | Owner | Work item | Acceptance |
| --- | --- | --- | --- | --- |
| ARCH-101 | P1 | Compose | Remove Apple products from `ComposeCore` | `Package.swift` and source-import gate prove Core depends only on model/SPI targets |
| ARCH-102 | P2 | Compose/runtime | Move DTO/archive/live API translation into provider | Public Core API contains no Apple types; existing CLI behaviour and tests remain stable |
| ARCH-103 | P2 | Stack | Generate a typed runtime capability/version manifest | Startup reports exact missing capability; stock Apple and matched-fork behaviour are deterministic |
| FORK-104 | P1 | Stack | Reclassify all 394 non-merge fork commits against current Apple heads | Every commit is bug fix, generic primitive, temporary port, or rejected Compose policy; no unowned delta |
| FORK-105 | P2 | Stack | Upstream generic slices and remove merged ports | Each retained slice has focused tests, Apple issue/PR, and deletion condition |
| FORK-106 | P2 | Stack | Converge local #799, #813, #87 equivalents | Apple merge or explicit replacement is recorded; duplicate code is removed without behaviour loss |
| DOC-107 | P2 | Compose | Replace 581 handoff documents with a compact generated registry plus active drafts | One row per capability/PR with owner, commit, state, last verification, and archive link; superseded drafts archived outside active tree |
| SDK-108 | P2 | Apple/Compose | Track lightweight SDK/API work (#1759/#1925) | Provider depends on a stable minimal client surface when available; no private XPC/storage dependency |

Phase gate:

- clean provider-boundary build;
- full Compose CI and live release gate pass against exact pins;
- fork delta report is generated and reviewed on every pin change;
- no merged Apple patch remains duplicated locally.

### Phase 2: Network Identity and Service Discovery

Goal: unlock the largest group of user-visible Compose gaps.

Dependencies: Phase 1 capability boundary; Apple DNS/listener design.

| ID | Priority | Owner | Work item | Acceptance |
| --- | --- | --- | --- | --- |
| NET-201 | P1 | Apple runtime | Deliver container-facing network-scoped DNS listener | Containers resolve service and container names only on shared networks; updates are atomic |
| NET-202 | P1 | Apple runtime | Register aliases with attachment lifecycle | Create/connect/disconnect/delete update records; collisions and stale records are deterministic |
| NET-203 | P1 | Compose | Map service names, `networks.aliases`, `--use-aliases`, and links to DNS | Docker parity covers scale, recreate, static IP, address change, and alias collision |
| NET-204 | P2 | Apple runtime | Define durable multi-container sandbox with independent network namespaces | PID/IPC sharing does not collapse network isolation; lifecycle and recovery are tested |
| NET-205 | P2 | Compose | Implement `network_mode: service:` and `container:` after NET-204 | Namespace identity, dependency order, teardown, and error parity pass |
| NET-206 | P2 | Apple/Compose | Complete feasible IPAM fields | Disabled IPv4, multiple pools, IPv6 range/aux, and error parity are explicit |
| NET-207 | P3 | Apple/Compose | Define custom driver/IPAM extension boundary | Unsupported drivers fail by capability; no metadata-only false success |

Phase gate:

- multi-service DNS and aliases pass live Docker parity;
- network changes survive recreate and scale;
- no cross-network name leakage;
- `links` and `external_links` limitations are either closed or explicitly
  scoped.

### Phase 3: Lifecycle, Logs, State, Events, and XPC Reliability

Goal: make long-running and interactive workloads predictable.

| ID | Priority | Owner | Work item | Acceptance |
| --- | --- | --- | --- | --- |
| LIFE-301 | P1 | Compose | Orchestrate `pre_start` helpers using pinned primitives | Inherited mounts/networks/env/user/workdir, failure propagation, cleanup, and Docker parity pass |
| LIFE-302 | P1 | Compose | Run lifecycle hooks around interactive foreground `run` | Reattach, signal proxy, detach keys, hook order, exit status, and cancellation pass |
| LOG-303 | P1 | Runtime | Stabilise signal payload, tail boundaries, and multiwriter fan-out | #1941, #1967, #2009 regressions pass under Compose attach/log/kill |
| XPC-304 | P1 | Apple/runtime | Resolve delayed-reply continuation crash and startup error masking | No continuation misuse; bootstrap root cause preserved; repeated start/stop soak passes |
| STATE-305 | P2 | Runtime/Compose | Add feasible `dead`, `restarting`, and `removing` states | Inspect, `ps`, filters, wait, and transition parity pass |
| EVT-306 | P2 | Runtime/Compose | Add oom, explicit restart, rename, resize, update, attach/detach events | Event order, attributes, JSON/text rendering, filters, and no duplicate remove action |
| STATS-307 | P2 | Runtime/Compose | Complete machine-backed CPU/memory statistics | Streaming/no-stream output has defined denominators and Docker-compatible unavailable values |
| LIFE-308 | P2 | Runtime/Compose | Reproduce and close exec/stop hangs (#1916) | Bounded stop/exec cancellation; no leaked process, VM, XPC session, or continuation |

Phase gate:

- interactive attach/run/exec/stop soak passes;
- log continuity survives client death;
- state and event traces match documented Docker sequences;
- runtime startup failures name the real launchd/XPC cause.

### Phase 4: Copy, Storage, Security, and Resource Controls

| ID | Priority | Owner | Work item | Acceptance |
| --- | --- | --- | --- | --- |
| COPY-401 | P1 | Containerization/container | Complete direct tar stream API (#812/#1947) | Bounded backpressure, cancellation, path safety, uid/gid/mode/link/time fidelity, and large streams |
| COPY-402 | P1 | Compose | Replace host staging with direct stream adapter | Docker `cp -` and `--archive` metadata parity passes in both directions |
| VOL-403 | P2 | Runtime | Define non-local volume driver/plugin contract | Unsupported driver never creates a misleading local ext4 volume |
| MOUNT-404 | P2 | Runtime/Compose | Implement recursive bind and feasible consistency/cache modes | Nested bind (#1890), subpath, hardlink, and live-update tests pass |
| SEC-405 | P1 | Containerization/container | Land seccomp and security-profile primitives | Typed profile load, validation, defaulting, and denial tests; no Compose policy in runtime |
| SEC-406 | P2 | Runtime/Compose | Add custom user mappings and remaining isolation fields | Mapping validation, ownership, namespace, and error parity pass |
| RES-407 | P2 | Runtime/Compose | Add realtime CPU, swappiness, and OOM-kill controls | Cgroup values and Docker zero/default semantics verified in guest |
| DEV-408 | P3 | Runtime/Compose | Define feasible CDI/GPU/device expansion | Capability-based selectors; unsupported vendor requests fail clearly |
| API-409 | P3 | Apple/Compose | Define authenticated API-socket proxy before `use_api_socket` | Least-privilege boundary, credential lifecycle, and threat model reviewed |
| STORE-410 | P2 | Apple/Compose | Add disk-usage and safe snapshot pruning | Project and system views account for snapshots; active resources cannot be pruned |

Phase gate:

- copy parity includes metadata, not only content;
- security/resource settings are verified inside the guest;
- unsupported volume/device/API features fail before side effects;
- repeated project lifecycle leaves no unowned VM, mount, or snapshot.

### Phase 5: Remaining Compose-Owned Feature Parity

| ID | Priority | Owner | Work item | Acceptance |
| --- | --- | --- | --- | --- |
| OUT-501 | P2 | Compose | Implement Go-template control actions and nested/map traversal | `if`, `with`, `range`, nested paths, map order, functions, and error parity for `ps`, `stats`, `volumes` |
| DEPLOY-502 | P2 | Compose | Preserve Docker local-mode Deploy metadata | Config/convert round trips mode, placement, update, rollback, reservations, and limits without pretending to schedule |
| MODEL-503 | P3 | Runtime/Compose | Select and integrate a model-runner backend | Model lifecycle, endpoint readiness, variable injection, failure cleanup, and secrets reviewed |
| LOG-504 | P2 | Runtime/Compose | Add distinct local/json-file and extensible logging drivers | Rotation, buffering, blocking mode, options, and plugin failure semantics pass |
| LINK-505 | P2 | Compose | Complete legacy link behaviour after DNS | Shared-network selection, aliases, dynamic updates, and any retained env semantics match oracle |
| PARITY-506 | P2 | Compose | Add regression probes for every confirmed gap | No fully-supported status row lacks a behaviour-level oracle or justified platform exemption |

Phase gate:

- no Compose-owned item remains in the runtime gap column;
- status is generated from executable capability tests where practical;
- full local-mode Docker Compose parity suite passes against v5.3.1 or a
  deliberately updated pinned oracle.

### Phase 6: Build Performance and Ecosystem Integration

| ID | Priority | Owner | Work item | Acceptance |
| --- | --- | --- | --- | --- |
| BUILD-601 | P2 | Builder/container | Adopt custom BuildKit frontends (#83) | Syntax-selected frontend, digest pinning, entitlement/security review, and fallback tests |
| BUILD-602 | P3 | Builder/container | Adopt JSON context transfer (#84) | Benchmarked improvement, bounded memory, path safety, cancellation, and tar fallback |
| BUILD-603 | P2 | Builder | Repair ineffective prefetch stress assertions | Race suite has deterministic liveness/correctness thresholds; benchmarks are separate |
| BUILD-604 | P3 | Container/Compose | Add image ID file support (#1998) where required | Atomic file write, no partial value, digest parity, and clear permission errors |
| ECO-605 | P3 | Apple/Compose | Support Dev Containers through stable API capability, not CLI scraping | Attach, exec, copy, ports, lifecycle, and feature install have versioned contracts |
| ECO-606 | P3 | Stack | Publish machine-readable capability and compatibility data | Tools can determine supported Compose/runtime/build features without parsing prose |
| PERF-607 | P3 | Stack | Establish representative performance baselines | Startup, 10/50-service up, logs, sync, build context, and teardown regressions are gated |

Phase gate:

- builder race and liveness tests are meaningful;
- performance changes have before/after data;
- ecosystem integration uses stable public interfaces;
- capability negotiation replaces version guessing.

## Validation Evidence

### Passed

- `HAWKEYE_AUTO_INSTALL=1 make ci` in clean `container-compose`
  - Python coverage tooling: 4 tests
  - release tooling: 155 tests
  - CI tooling: 14 tests
  - Swift: 1,124 tests in 26 suites passed
  - Go normaliser aggregate coverage: 89.88%
  - configured `ComposeCore` line coverage: 91.46%
  - CLI smoke completed
- `make docker-compose-cli-surface-parity`
  - Docker Compose reference: v5.3.1
  - 41 option surfaces and 3 command-list surfaces compared
  - no unexpected differences
  - four documented local differences: `alpha`, `convert`, `help`, and
    root-help visibility of `--verbose`
- `HAWKEYE_AUTO_INSTALL=1 make check` in exact pinned `container`
- exact pinned `container` hosted `Package` and `Build and test project`
  checks were successful
- `make check` in exact pinned `containerization`
- `make test` in exact pinned `containerization`
  - 647 tests in 85 suites passed
- `make vet test` in exact pinned `container-builder-shim`
- `make test-race` in exact pinned `container-builder-shim`
- Docker Engine 29.5.2 was available for oracle-side checks.

### Not Claimed

- The full live `make release-gate` was not rerun. The Apple container
  `apiserver` was not running or registered with launchd, and starting a
  machine-wide service was outside this read-only review.
- The 25 Compose runtime smoke tests did not execute in `make ci`; they returned
  early because the live-runtime environment variable was unset.
- No live commit-volume or tar ownership parity test currently exists, which
  is why those defects were found by source/data-flow review.
- `containerization` has no fork-hosted GitHub Actions evidence at the reviewed
  pin; local `make check` and 647-test execution provide the current evidence.
- Open Apple pull requests marked `BLOCKED` or `DIRTY` were not treated as
  ready dependencies.

## Release Gate for Future Phases

Every phase should finish with:

1. exact-pin fetch and support-fork divergence review;
2. targeted unit and regression tests;
3. format, lint, static analysis, dependency, generated-source, and diff
   checks;
4. aggregate and target-specific coverage review;
5. `HAWKEYE_AUTO_INSTALL=1 make ci`;
6. live runtime smoke with explicit executed/skipped counts;
7. Docker Compose behaviour parity for changed commands and metadata;
8. full `make release-gate` on a registered Apple runtime;
9. strict manual review for correctness, API compatibility, security,
   maintainability, documentation, release impact, and avoidable fork delta;
10. final re-fetch and validation of the actual commits intended for release.

No phase is complete while a fully-supported status claim lacks either a
passing behaviour-level check or an explicit, reviewed platform exemption.
