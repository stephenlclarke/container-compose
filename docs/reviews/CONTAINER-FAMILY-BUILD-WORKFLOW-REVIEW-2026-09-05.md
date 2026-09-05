# Container-family build workflow review — 5 September 2026

## Purpose

This record captures observed build defects, elapsed timings, and the first
workflow consolidation pass. It is deliberately separate from release and
benchmark evidence. The goal is to make a later build-system refinement use
measured failures rather than repeat discovery.

The reliability follow-up is tracked by [issue #488](https://github.com/stephenlclarke/container-compose/issues/488).

## Changes in this iteration

The recoverable Nextflow stack graph previously used 12 isolated functional
stages. It now uses eight. Each stage still receives an immutable source
snapshot and keeps a durable receipt, but related build and test commands for
one repository share the same checkout and compiler cache.

- Compose Swift tests, the debug product build, and CLI smoke tests now run in
  one stage. Compose Go tests and the stripped normalizer build run in one
  parallel stage. This removes the third isolated Compose checkout that rebuilt
  both languages only for smoke tests.
- Builder coverage and its executable build now share one Go cache instead of
  running in separate isolated stages.
- Containerization tests and the signed host product build now share one Swift
  cache instead of running in separate isolated stages.
- Container now runs its unit suite before its product build. The previous
  stack graph built Container but did not test it.
- Engine API now runs the test bundle it builds before compiling the
  performance fixture. The previous graph built tests without executing them.
- Devcontainer now runs its unit suite before the product build. The previous
  graph built it but did not test it.
- Container Kubernetes tests, product build, and CLI smoke checks now share one
  Swift cache instead of using two isolated stages.
- Source stages use the already installed Hawkeye executable directly. They no
  longer create a disposable `.local/bin` link in every snapshot.
- Builder source validation now asks Go to load the vendored package graph so a
  stale `vendor/modules.txt` fails before the expensive functional stage.

This consolidation removes four whole task sandboxes and their duplicate
dependency planning/build work while increasing functional coverage in three
repositories.

The follow-up reliability pass keeps stage execution roots under the bounded `/private/tmp/ccp.*` prefix so nested Unix-domain sockets remain below Darwin's 103-byte limit. The Compose source stage now performs only fail-fast source validation; Python tool and parity-harness tests run once in the existing Compose Go lane with four-way Make parallelism, concurrently with Swift validation. Nextflow cancellation is forwarded explicitly from each repository task shell to the deadline supervisor, which already owns process-session cleanup, so a failed sibling stage cannot leave a fixture process running after its task is terminated.

## Timings observed during the corrective work

These are wall-clock measurements on the same Apple silicon host. They are
diagnostic timings, not performance benchmarks: cache temperature and the
source graph differed between commands.

- Containerization `make check`: 3.27 seconds.
- Containerization full `swift test`: 47.37 seconds wall time; 912 tests passed.
- Containerization focused terminal test after the relevant build: 22.65
  seconds; three tests passed.
- SwiftNIO SSL first focused build: 49.13 seconds for a very small test subset.
- SwiftNIO SSL full suite after compilation: 18.63 seconds wall time; 347 tests
  passed.
- SwiftNIO SSL exact parser regression after warm-up: 5.65 seconds.
- Builder grouped tests with dependency preparation: 26.91 seconds.
- Builder warm Go test run: 5.60 seconds.
- Container first focused invocation compiled roughly 3,100 targets and spent
  92.84 seconds to execute a millisecond-scale test.
- Adding the vmnet test target invalidated the Container package test plan. The
  first attempt compiled for 97.94 seconds before rejecting an availability
  annotation; the corrected retry then compiled for 88.48 seconds and ran three
  focused tests in 0.001 seconds. The second focused vmnet suite reused that
  build and completed in 1.30 seconds.
- Container's first broad direct `swift test` completed in 166.41 seconds but
  reported 32 missing semantic-helper issues because the direct invocation had
  bypassed the Make prerequisite. `make semantic-helper` took 5.21 seconds;
  the no-rebuild rerun then passed 2,472 tests in 49.50 seconds wall time.
- After a manifest-only dependency update, Container's focused configuration
  and release-version run spent 100.81 seconds building before 40 tests ran in
  0.02 seconds. A later focused network run spent 96.11 seconds building before
  30 tests ran in 0.005 seconds. This is the clearest measured target for
  improving local edit-to-result latency.
- Even after the package was warm, changing one small public runtime-client
  method caused 66.43 seconds of planning, recompilation, and relinking before
  four waiter tests ran in 0.001 seconds. The edit crossed target boundaries,
  but the ratio still shows that invocation and link topology dominate focused
  feedback.
- The real cancellation proof completed Compose source validation in 10.5
  seconds, interrupted the active Go/tool stage, returned the original 130
  status, and left no deadline runner, fixture process, or `/private/tmp/ccp.*`
  root behind.
- The first optimized repository checkpoint ran Compose source validation in
  10.5 seconds and completed the parallel Swift lane in 5 minutes 59 seconds.
  The Go/tool lane stopped after 9 minutes 42 seconds on one stale
  wall-clock-sensitive test rather than hiding or retrying it.
- The corrected exact implementation head completed the repository profile in
  9 minutes 23 seconds. Source validation took 10.6 seconds, Swift validation
  took 5 minutes 5 seconds, and the parallel Go/tool lane took 8 minutes 58
  seconds. All three receipts and the final summary were complete.

Hosted checks on the merged reviewed heads provide a second, reproducible
timing set:

- Containerization guest initfs: 7 minutes 29 seconds.
- Containerization macOS build and test: 14 minutes.
- Containerization Linux compile: 19 minutes 45 seconds.
- Compose source validation: 2 minutes.
- Compose tool tests (`ci` profile): 6 minutes 48 seconds.
- Compose tool tests (`release` profile): 8 minutes 20 seconds.
- Compose runtime validation: 12 minutes 27 seconds.

One superseded Container workflow was cancelled as soon as exact-head review
found defects. It had already spent about 9 minutes 12 seconds preparing
protobuf before product compilation began. This confirms that review and
dependency checks should gate the costly hosted build whenever the platform
allows it, and that stale-head cancellation must be verified rather than
assumed from the first cancellation request.

The Nextflow trace, report, timeline, receipts, stdout, and stderr from every
future pipeline execution remain under the marked pipeline state root. Those
records provide stage-level timings suitable for comparing this eight-stage
graph with later refinements.

## Defects and reliability risks found

### Fixed here

- Functional stages used fresh task roots for test and build steps from the
  same repository, forcing duplicate Swift and Go work.
- The normal stack graph omitted Container and devcontainer unit execution and
  omitted Engine API test execution.
- Builder vendoring drift was discovered only after a functional command had
  started.
- Three Makefiles tried to bootstrap Hawkeye even when a verified executable
  was already on `PATH`. The corresponding fork fixes now support direct reuse;
  paths containing spaces are quoted.
- Direct raw `swift test` for Container can bypass the semantic-helper producer.
  The supported pipeline command now uses Make, which owns that prerequisite.
- Long per-stage execution roots left too little of Darwin's Unix-socket path budget for nested release-tool fixtures. Fifty-four tests failed and one errored after about 247.85 seconds even though the product behavior was unchanged. Stage roots are now short and the path budget has a focused regression.
- A terminated devcontainer source stage left its fake `colima start` descendant alive after Nextflow aborted the graph, which could trigger an unattended Keychain dialog. The task shell now forwards HUP, INT, QUIT, and TERM to the process-session supervisor and waits for its bounded cleanup before removing stage state.
- Compose source validation serialized release, CI, coverage, and parity-harness tests before either functional lane could start. Source validation is now static and fail-fast; the executable tool suites run once with bounded parallelism alongside Swift validation.
- The API-round-trip deadline test spent half of its six-second budget in the
  harness's intentional three-second stale-service delay, so it could expire
  before reaching the API hang it was meant to exercise. Its fixture now
  bypasses only that fixed delay, retains the simulated 30-second API hang,
  and reports the invocation log on a count mismatch.

### Still open for a later build-system iteration

- The top-level plain `make` path is not the recoverable family pipeline. It
  builds and packages Compose locally, but a failure requires manually deciding
  what can be reused. The recoverable command remains `make pipeline-bootstrap`
  followed by `PIPELINE_PROFILE=stack make pipeline`; a successful build can be
  resumed with its exact session UUID.
- The recoverable stack phase validates source, unit behavior, builds, and
  smoke checks, but it does not yet publish a reusable local distribution
  artifact. Artifact-producing packaging should become a downstream task that
  consumes validated build outputs rather than rebuilding them.
- Source and functional stages still use separate immutable snapshots. That is
  a valuable fail-fast boundary, but Swift formatting/license checks and
  dependency planning can both touch much of a large tree. Trace evidence is
  needed before deciding whether any source work should be consolidated.
- SwiftPM repeatedly warns about two dependency URLs with the
  `swift-nio-ssl` package identity. A future SwiftPM release will turn this into
  an error. The matched dependency graph needs one canonical URL.
- SwiftPM emitted `maintenance.lock doesn't exist` warnings. Cache ownership
  and cleanup should be audited before enabling more concurrent Swift stages.
- Container's package graph makes genuinely focused tests expensive after any
  manifest or test-target change. Target-specific build products or a smaller
  test-support graph would give the largest cold-feedback improvement.
- A direct macOS build of the Linux-only `vminitd` package fails on its
  `FoundationEssentials` imports. The supported Containerization Make path
  correctly builds it in Linux; the CLI should fail fast with an explanatory
  message if someone invokes the unsupported host path.
- Nextflow 26.04.6 reports that six `shell` blocks are deprecated. Migration to
  `script` needs its own exact recovery proof because quoting and interpolation
  are security-sensitive here.
- Pipeline scheduling currently permits two repository stages but serializes
  all Swift-labelled stages. This was a deliberate response to contention in
  the 0.14 release. A later iteration should use trace CPU, memory-pressure, and
  duration evidence to determine whether one small Swift stage can safely run
  beside one large Swift stage.
- Failure cleanup is marker-protected, but stale Swift build products outside
  the Nextflow task roots are not centrally inventoried. A preflight should
  distinguish reusable content-addressed caches from incompatible products and
  quarantine only the latter, recording the producer and reason.
- The ordinary Compose workflow builds the Go normalizer during `ci` and again
  through `package-release`. Packaging should consume the already validated
  normalizer rather than rebuild it.
- Hosted workflows classify dependency-only changes as full product changes.
  The final Container stack-pin update therefore paid the same protobuf and
  broad-build setup cost as a runtime implementation change. Path and manifest
  impact analysis should select a smaller dependency-contract gate, while the
  merge queue retains one authoritative broad result for the final head.
- Container's normal PR workflow serializes formatting, protobuf validation,
  product build, package creation, unit tests, integration tests, and a second
  coverage test pass in one macOS job. Packaging is not required to establish
  most PR correctness, and coverage should consume the unit execution's raw
  profile instead of executing the same tests again. Independent integration
  and packaging lanes can start after one shared build artifact is accepted.
- Exact-head review and broad Container CI currently start independently after
  each push. Review findings repeatedly arrived while the expensive protobuf
  producer was already running, so superseded heads consumed hosted minutes
  before they could be force-cancelled. A reviewed-head promotion check should
  dispatch the broad build only after the requested review reaches that exact
  SHA with no open findings.
- Cancellation is asynchronous. A superseded Container run continued to hold
  its hosted macOS runner after two ordinary cancellation requests, delaying
  its replacement until the GitHub force-cancel endpoint was used. The
  controller should poll for terminal cancellation, force-cancel after a
  bounded grace period, and report the occupied runner as a blocked resource
  before dispatching the next expensive job.

## Next refinement priorities

1. Add a recoverable artifact-assembly stage that consumes validated Compose
   Swift and Go outputs and produces the local plugin archive without compiling
   either language again.
2. Make the plain `make` experience select that recoverable repository graph,
   while retaining explicit `make ci` and release commands for automation.
3. Add a content-addressed compatibility manifest for Swift build products,
   semantic-helper archives, Go vendoring, Xcode/SDK identity, and signing
   inputs. Quarantine mismatches before compilation and identify their producer.
4. Compare old and new Nextflow traces using cold and warm runs. Change
   concurrency only where elapsed time improves without memory pressure,
   approval dialogs, nondeterminism, or cache corruption.
5. Migrate deprecated Nextflow syntax with the recovery self-test as the
   acceptance gate.

The intended end state is a single unattended command with fail-fast
preflight, deterministic inputs, resumable checkpoints, no interactive
credential or local-network prompts, one execution of each necessary test, and
a usable local artifact at completion.
