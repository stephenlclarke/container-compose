# Recoverable Container-Family Builds

## Status And Scope

This document records the build, test, evidence, and recovery design for
`container-compose` and the related Container-family repositories. It also
distinguishes the phase-one implementation from the remaining migration. The
design implements the immutable-checkpoint and bounded-retry requirements in
the [Container-family parity development cycle](container-family-development-cycle.md)
without changing the vertical-slice delivery model described there.

The system is local-first. It must run on the development Mac, on a dedicated
self-hosted Mac runner, and in the hosted-safe subset described by the
[build guide](../guides/BUILD.md). GitHub Actions is an authority and dispatch
surface, not a second implementation of the build graph.

This decision selects the open-source Nextflow runtime as the orchestration
engine. Existing Make targets, runtime wrappers, deadline supervision, and
focused test commands remain the execution primitives during migration.
Nextflow owns the durable graph, scoped input identity, recovery state,
stage receipts, and operator view.

This document does not authorise a release, publication, destructive cleanup,
credential change, or macOS privacy approval. Publication remains an explicit
terminal action after immutable evidence has passed.

### Implemented In Phase One

The checked-in pipeline currently provides:

- a checksum-pinned Nextflow 26.04.6 launcher installed only by the explicit
  `make pipeline-bootstrap` target;
- a marker-protected durable state, cache, history, and evidence root on the
  external SSD when it is available;
- clean-repository and exact-commit preflight for Compose and seven related
  repositories;
- self-contained Git bundles for source-check stages and deterministic,
  declared path-scoped tree archives for functional and build stages;
- a same-repository source-check gate before each selected functional or build
  stage, without a global all-repository barrier;
- stage-specific command and tool manifests instead of one global fingerprint,
  including a recorded Bash 5 executable, the selected Apple developer
  directory and resolved front-door tools, the complete Go installation tree,
  and the installed `markdownlint-cli` package tree where applicable;
- source, build-only, and non-runtime functional stages that invoke existing
  repository commands through a sealed private tool directory plus the fixed
  system path, with the recorded developer directory pinned for every stage;
- internal-volume execution roots so generated executables do not run from the
  removable SSD;
- closed standard input, disabled credential prompting and automatic package
  updates, finite process-session deadlines across descendant groups,
  post-exit descendant cleanup, and a
  single state-root lock;
- exact-session resume by UUID, with no bare or manually edited resume mode;
- durable failed-stage receipts, commands, standard output, and standard error;
  and
- a fault-injection proof that a corrected downstream task completes while its
  successful upstream task is recovered from the content cache.

The current `stack` and `hosted-safe` profiles are independent family-health
graphs. They do not yet assemble or claim a matched runtime stack.

### Not Yet Migrated

The existing release gate remains the release authority. Phase one does not
yet replace its live runtime, parity, sanitizer, package, demonstration,
external-authority, or publication stages. It also does not yet capture dirty
development patches, export or verify reusable compiler products between
tasks, enforce coverage floors, or provision signing keychains and macOS
privacy grants. Missing-output and corrupt-output cache recovery also remain
future acceptance tests. Those boundaries must not be inferred from a
successful phase-one summary.

## Required Outcome

A source or test defect must fail at the smallest stage that can prove it. An
operator must be able to correct that defect and resume without rebuilding or
retesting independent exact inputs. Reuse must be automatic and auditable; no
one may edit a checkpoint, rewrite a digest, or copy a success marker forward.

An infrastructure failure must retain enough evidence to diagnose it and must
not invalidate successful functional proof. A missing external service,
locked signing credential, absent macOS permission, unsupported runner, or
interactive prompt risk must fail during preflight or in its own authority
stage before expensive work begins.

In the target system, every completed stage must prove both its inputs and its
declared outputs. Phase one proves the stage command, source payload, selected
tools, and completion receipt; its build and test products remain task-local
and it emits no output-artifact manifest. A phase-one success is therefore
reusable validation evidence, not a package or release artifact.

## Audit Baseline

The design is based on the repository and retained build evidence inspected on
23 August 2026. The audit covered the Make graph, local and GitHub test
harnesses, release scripts, runtime wrapper, checkpoint helpers, development
cycle, build guide, Git history, GitHub Actions history, and retained local
failure state.

The existing release gate has four sequential outer stages: sibling-stack
validation, Compose CI, Swift runtime validation, and the Docker Compose parity
suite. Sibling validation implements a second checkpoint system made of SHA
stamp files. The release script implements additional recovery state, while
GitHub Actions job state acts as another independent state machine. None of
these systems shares one dependency graph, artifact manifest, or failure
taxonomy.

The Docker Compose parity suite already has a useful decomposition into 65
named contracts. The sibling validation script also has useful per-repository
and per-target commands. The problem is not the absence of runnable stages; it
is the absence of one durable and correctly scoped graph around them.

### Evidence That Bespoke Checkpoints Failed

Six retained checkpoint roots under `/private/tmp` each contained 59 success
records. In each inspected root, 57 records contained a `carried_forward`
object. No repository code creates, reads, or validates that object. Some
records had been moved to a new source fingerprint with a rationale and
focused-test reference so unrelated successful work would not be repeated.

The pressure to do this came from one global release fingerprint. That
fingerprint binds every outer stage and every parity contract to all matched
repository trees, inherited environment, selected executables, runtime
candidate, tool versions, test controls, coverage floors, deadlines, and all
parity settings. A change that affects one Compose contract therefore
invalidates sibling repositories and every other parity contract.

The resulting carry-forward records may describe reasonable human judgement,
but they are outside the checkpoint implementation and cannot be verified by a
future operator. They undermine the claim that reuse is exact-input reuse. The
new system treats any mutation of cached task metadata as cache corruption and
never provides a manual carry-forward operation.

Retained failed checkpoints were also insufficient. One sibling-stack failure
recorded a 571-second duration and exit status 2 but retained neither output
stream nor a structured reason. It established that a command failed, but not
what failed, which inputs were consumed, which artifacts had already been
produced, or whether retry was safe.

### Repeated Failure Classes

The inspected GitHub history since 9 August contained 134 CI runs, including
14 failures and 38 cancellations. Prebuilt Binaries had 10 failures in 49
runs. Stable Release Gate had three failures in five runs. Quality had four
failures and 16 cancellations in 73 runs. Verify Upstream PR Archives failed
nine of ten runs.

The recurring patterns were:

- dependency and consumer-contract drift, including a new inbound socket
  capability whose Compose expectation fixture still described the old list;
- expensive work performed before runner capability checks, including a
  hosted run that completed thousands of Container build steps before nested
  virtualisation proved unavailable;
- host-tool differences, including system Bash being used where Bash 5
  behaviour was required;
- external authority coupled to functional validation, including GPG agent and
  socket-path faults, Sonar availability, and scanner failure;
- OCI input drift, including retained archives that did not contain the newly
  pinned exact reference, platform, or complete closure;
- runtime and recording faults, including readiness timeouts, an optimised
  freed-pointer crash, missing stats output, disappearing containers, and VHS
  timeout;
- test-isolation faults found late by whole-suite sanitizer runs;
- cancelled GitHub jobs losing all useful progress because their durable
  checkpoint state was not exported; and
- persistent auxiliary authority failures, such as expected archive branches
  being absent, obscuring the state of the product build.

The Git history contains many narrowly successive repairs for fingerprint
inputs, deadlines, signal propagation, interrupted cleanup, Bash selection,
socket lengths, compiler profiles, runtime identity, retained OCI selection,
builder bootstrap, GPG setup, and pin drift. Those repairs improved individual
scripts but also show that the bespoke system has become a reactive collection
of exception paths.

The runtime reliability history in
[the runtime-validation issue](../upstream/container-compose/ISSUE-container-runtime-validation-reliability.md)
provides another important constraint: an advisory runtime lock is effective
only when every local process and runner cooperates, and a self-hosted runner
must not replace the stable per-user XPC services while another validation owns
them.

## Why Nextflow OSS

Nextflow OSS provides the smallest appropriate replacement for the missing
orchestration layer:

- a content-addressed process cache with explicit resume semantics;
- declared inputs, outputs, and dataflow dependencies;
- safe fan-out for sibling targets and parity contracts;
- process-level retry, timeout, resource, and executor policies;
- local execution without requiring a service or hosted control plane;
- execution profiles for development, self-hosted, hosted-safe, sanitizer, and
  release use;
- durable trace, report, timeline, and workflow-DAG evidence; and
- one graph that GitHub Actions can invoke rather than reimplement.

Only the open-source runtime is required. No hosted Nextflow control plane,
commercial service, cloud executor, container-only executor, or external
database is required for the initial system. The Nextflow version and launcher
digest must be pinned and cached before an unattended run. Release profiles
must be able to run with the pinned runtime already present and with Nextflow's
offline mode enabled.

Nextflow is not trusted to infer every result-affecting host input. The pipeline
must pass explicit manifests and use deep content hashing for source snapshots,
tool manifests, and artifact inputs. It is also not a replacement for the
host-global Container runtime lock, stable macOS code identity, marker-protected
runtime roots, or publication transaction logic.

### Alternatives Considered

Extending the Python checkpoint helper was rejected as the primary design. It
would require implementing a workflow language, dependency scheduler, durable
journal, cache database, output validation, retry engine, profiles, reporting,
and resume planner. The carry-forward evidence demonstrates the cost of
continuing to grow that bespoke engine.

Make remains a good command adapter but is not the recovery database. Its
timestamp model does not prove immutable multi-repository inputs, output
digests, host resources, or an interrupted long-running test.

GitHub Actions alone was rejected because local development and self-hosted
runtime validation need the same graph. Workflow cancellation, runner cleanup,
and job boundaries currently discard reusable local progress. GitHub remains
the remote authority, event source, and evidence publisher.

Bazel and Nix offer stronger hermetic build models, but adopting either across
SwiftPM, Xcode/macOS signing, launchd/XPC services, Virtualization.framework,
Docker comparison, and existing Make contracts would be a substantially larger
programme. They would still need host-runtime orchestration and privacy
preflight.

Container-centred systems such as Dagger, Earthly, Tekton, and Argo are a poor
fit for the stages that must run signed binaries through launchd and
Virtualization.framework on the Mac host. General schedulers such as Airflow
would add a service and operational database without improving build-artifact
identity.

## Source And Run Identity

The complete manifest described below is the target state. Phase one records a
smaller repository receipt containing the canonical source path, requested
reference, commit, tree, and clean-worktree result. Source checks receive a
self-contained bundle rooted at that exact commit, including tags only where a
declared command needs them. Functional and build stages receive deterministic
tree archives containing only their declared paths and only the Git metadata
their command declares. Together, the phase-one attempt, host/tool preflight,
and stage receipts record the selected profile, stage selector, launcher
identity, command digest, source-payload digest, stage-tool digest, and
deadlines.

In the target state, every invocation begins by creating a fuller immutable run
manifest. That manifest is the root input to the graph and records:

- pipeline schema and pinned Nextflow launcher identity;
- selected profile and authorised terminal boundary;
- repository name, remote, commit SHA, tree SHA, branch, and dependency pins;
- either a clean-worktree assertion or a content hash of an explicitly captured
  development patch;
- exact Swift, Xcode, Go, Python, Docker, Docker Compose, signing, and helper
  executable identities;
- selected runtime, guest/init image, builder image, normalizer, Docker oracle,
  and fixture digests;
- declared result-affecting environment values;
- host and runner capability manifest;
- stage policy, timeouts, retry limits, coverage floors, and selected parity
  contracts; and
- the stable evidence and work roots.

All implemented profiles reject dirty repositories. A later development
profile may capture a dirty patch as a first-class immutable input, but it must
never identify modified sources only as `HEAD^{tree}`.

The environment is allowlisted, not inherited wholesale. A new environment or
Make override that can affect a result must be added to the relevant process
input schema. Session identity, terminal state, random temporary locations, and
evidence destinations are excluded. An undeclared override fails closed in
future release profiles instead of silently changing a command or globally
invalidating unrelated work.

## Stage Graph

Phase one implements this graph:

```text
HOST_PREFLIGHT ────────────────┐
REPOSITORY_RECEIPT ────────────┼── STAGE_SOURCE_INPUT
                               └── STAGE_TOOL_MANIFEST
                                          │
                                          └── SOURCE_STAGE
                                                    │
                                                    └── FUNCTIONAL_OR_BUILD_STAGE
                                                                  │
                                                                  └── SUMMARY
```

Every selected functional or build stage depends on the source-check receipt
for the same repository; repositories do not wait on unrelated repositories.
The functional and build stages validate their commands and emit completion
receipts, but do not publish reusable compiler products or output-artifact
manifests to another task. The larger graph below is the migration target, not
a description of release authority that exists today.

```text
SNAPSHOT_INPUTS ───────────────┐
PREFLIGHT_HOST ────────────────┤
                               ├── SOURCE_CHECKS
                               ├── BUILD_COMPOSE
                               ├── BUILD_NORMALIZER
                               └── BUILD_MATCHED_RUNTIME
                                         │
                 SOURCE_CHECKS ──────────┤
                 BUILD_COMPOSE ──────────┤
                 BUILD_NORMALIZER ───────┴── UNIT_COVERAGE_SMOKE
                                         │
                 BUILD_MATCHED_RUNTIME ──┴── SIBLING_STACK_TARGETS
                                         │
                                         └── RUNTIME_CONTRACTS
                                                   │
                                                   └── PARITY_TARGETS
                                                             │
                                                             └── PACKAGE
                                                                    │
                                                                    └── DEMO
                                                                           │
                                                                           └── AUTHORITY
                                                                                  │
                                                                                  └── PUBLISH
```

`SNAPSHOT_INPUTS` validates and archives the selected repository sources and
creates the run manifest. It does not put all repository archives into every
downstream process.

`PREFLIGHT_HOST` proves the selected profile can run before a compiler starts.
It checks tools, disk capacity, filesystem placement, path and socket limits,
virtualisation capability, Docker reference, runner labels, runtime lock and
service state, signing setup, registry mode, exact OCI references and closure,
and the no-prompt contract.

`SOURCE_CHECKS` runs license, formatting, generated-output, Markdown, policy,
stack-ref, and handoff consistency checks. It consumes only repositories and
tools needed by those checks.

`BUILD_COMPOSE` produces the Swift test bundle and debug/release products
selected by the profile. `BUILD_NORMALIZER` produces the Go helper. Both emit
artifact manifests. `BUILD_MATCHED_RUNTIME` produces or validates the exact
Container-family runtime candidate, guest/init archives, and builder inputs.

`UNIT_COVERAGE_SMOKE` consumes the immutable build outputs. Unit execution must
use `--skip-build` or its equivalent so the tested bytes are the bytes in the
artifact receipt. Coverage and CLI smoke results are distinct declared outputs
even if they remain one initial process.

`SIBLING_STACK_TARGETS` maps existing builder, containerization, container, and
Homebrew validation targets into separate Nextflow tasks. Each task consumes
only its repository snapshot and explicitly required runtime artifact.

`RUNTIME_CONTRACTS` runs the bounded Compose runtime suite using the matched
candidate. It holds the host-global runtime lock and emits service logs,
runtime identity, socket identity, events, cleanup result, and JUnit evidence.

`PARITY_TARGETS` maps the existing 65 contract names into independently cached
tasks. Runtime-consuming tasks continue to hold the host-global lock. The first
migration may serialize them for safety; later isolated-runtime evidence may
permit bounded concurrency.

`PACKAGE` consumes tested artifact digests rather than rebuilding mutable
sources. It produces the archive, checksum, signature receipt, and provenance
manifest.

`DEMO` validates the packaged bytes and records the Current demonstration. A
demo failure cannot invalidate package construction, unit proof, or parity
proof.

`AUTHORITY` reads external GitHub, CodeQL, Sonar, and release-policy evidence.
It is independently retryable and cannot convert an unavailable external
service into a source failure.

`PUBLISH` is excluded unless the operator selects the publication profile and
provides explicit authority. It verifies every upstream artifact digest before
performing GitHub release and Homebrew mutations. It remains non-cancellable
once the external transaction begins and records each idempotent mutation.

## Exact Invalidation Model

In phase one, every source check consumes a self-contained Git bundle for its
repository's exact commit because those checks can legitimately inspect Git
history, tags, or the complete tracked tree. Functional and build stages for
Compose and every related repository instead consume deterministic tree
archives containing only their declared paths. The Compose Swift-test and
CLI-smoke stages include `Package.swift`, `Package.resolved`, `Sources`,
`Tests`, `Tools`, `scripts`, `Makefile`, and `config.toml`; CLI smoke also
includes its packaged icon. The Compose Go test consumes only
`Tools/compose-normalizer` and `Makefile`. Related-repository test and build
stages likewise declare their package, source, test, vendor, signing, or helper
paths explicitly.

Each stage also consumes only its declared command, source metadata, and tool
manifest. A functional or build stage is gated only by its own repository's
source stage. Nextflow may reuse a process only when its process definition,
declared scalar inputs, and declared file inputs retain the same content
identity and the cache entry remains usable. Phase one verifies source payload,
command, and tool identities and emits stage receipts; it does not create or
verify an output-artifact manifest.

Current inputs are scoped to the consumer:

- a Compose documentation change invalidates Compose source checks but not a
  previously proved Container runtime build;
- a Compose Swift source change invalidates the Compose Swift test and CLI
  smoke, but not the path-scoped normalizer test or unrelated repositories;
- a related repository change invalidates its full source check and only the
  related functional/build stages whose declared paths changed; and
- selecting a functional stage automatically selects that repository's source
  stage without selecting other repositories.

Runtime, parity, coverage-floor, package, authority, and publication
invalidation remain target behavior for later migration; no phase-one profile
runs or claims those boundaries.

Transitive invalidation follows declared channels. A global static fingerprint
must never be passed to every process. Cache metadata must never be edited to
force reuse. When independent proof is legitimately reusable, the graph makes
that independence explicit and Nextflow finds it naturally.

Failed and interrupted tasks are not successful cache entries. A subsequent
exact-session resume reruns them while independently successful content-matched
tasks can be reused. Release checkpoints, formula preflight, and published
artifact verification now fail before expensive successors; explicit
missing-output and corrupt-output recovery tests remain future acceptance
criteria for the broader Nextflow graph.

## Release fail-fast graph

The release graph orders checks by cost and by how much downstream work they
can invalidate:

1. Resolve immutable source and stack references, repository cleanliness,
   release intent, host capability, retained OCI inputs, signing identity, and
   available disk.
2. Validate the Homebrew tap origin, clean state, Ruby syntax, exact release
   URLs, SHA-256 values, stable/current lane pairing, source formula templates,
   and promotion-token push permission.
3. Run release-only CodeQL for the exact package source.
4. Build one immutable runtime and Compose package candidate, then fan it out
   to tests, signing, parity, and publication rather than rebuilding it.
5. Publish only after every authority is green. A Current demo is a deferred,
   non-authoritative consumer and stable package runs never dispatch it.
6. Classify documentation inputs. Benchmark-only, unrelated, and proven
   implementation-only Swift changes skip DocC. Public declarations, API
   comments, docs, package resolution, toolchain selectors, and workflow inputs
   rebuild it; ambiguous Swift syntax fails safe by rebuilding.

Independent DocC sites fan out in parallel with matrix fail-fast enabled, then
Pages assembly runs only if every site succeeds. CodeQL and DocC are not part
of ordinary development or benchmark-report validation. Published benchmarks
consume signed GitHub/Homebrew artifacts and dispatch only the documentation
CI path.

## Durable SSD State And Internal Runtime State

Source-of-truth repositories remain in their normal `~/github` locations.
Immutable source archives, Nextflow launch state, content-addressed work
directories, downloaded tool distributions, recovery proofs, and retained
attempt evidence live below a marker-protected root on
`/Volumes/SSD/github`. The wrapper selects a stable pipeline root rather than a
random temporary directory so the Nextflow session, cache, and work artifacts
survive a Codex restart, terminal exit, GitHub runner restart, or ordinary
worktree cleanup.

The external SSD is storage, not a runtime execution root. Future macOS
launchd/XPC services, Virtualization.framework helpers, signed runtime
executables, service-readable OCI archives, app state, sockets, temporary
signing keychains, and configuration homes must be staged under
marker-protected paths on the internal system volume. The planned staging base
is `/private/tmp`, with a stable user and artifact-digest component. Existing
socket paths under `/tmp` remain short and user-scoped.

When runtime and package stages are migrated, internal staging will copy an
immutable SSD artifact to a partial file, verify its content digest and code
signature, atomically rename it, and write a receipt connecting the internal
path to the source artifact manifest. That future staging will have its own
lock. Process-name probing is not a lock. Cleanup must refuse an unmarked path
and must not remove a candidate still owned by another run.

Phase-one source, build, and test commands extract their immutable source
archives into marker-protected execution directories under `/private/tmp`.
This prevents generated executables from running directly on the removable
volume while retaining cache and evidence on the SSD. The stronger
digest-and-signature staging contract in the preceding paragraph applies when
runtime and package artifacts are migrated; no phase-one profile starts the
Container runtime.

## Unattended No-Prompt Contract

Phase one enforces this contract for source, build-only, and non-runtime
functional stages. It closes standard input, clears the inherited environment,
uses an isolated home and Docker configuration, disables Git credential
prompts and Homebrew auto-update, and bounds every stage. Stage commands run
from marker-protected internal-volume roots with a sealed private tool
directory followed by `/usr/bin:/bin:/usr/sbin:/sbin`. Swift stages pin and
revalidate the recorded `DEVELOPER_DIR`. Keychain, signing,
registry-authenticated, TCC, and live-runtime work is excluded until the later
preflights described below exist.

An unattended profile must never wait for a terminal, GUI approval, password,
credential helper, package installer, or macOS privacy dialog. The contract is
fail-fast. Phase one excludes prompt-prone capabilities; when they are
migrated, preflight must reject any capability that cannot be proved
noninteractively before expensive work. Structured
`blocked-host-policy` classification belongs to the later prompt-prone host
stages; phase one records only the declared `source`, `test`, or `build`
classification for repository stages.

Every process receives closed standard input and an explicit noninteractive
environment. It disables Git terminal prompting, interactive credential
managers, SSH askpass, Homebrew automatic updates, and interactive tool
installation. Required tools and the pinned Nextflow launcher are installed
before the run or the run fails. No process invokes `sudo`.

Future registry stages must use an explicit anonymous-host configuration for
public GHCR artifacts and an isolated registry configuration, avoiding
login-keychain credential lookup. Authenticated registry tests must receive a
purpose-specific, noninteractive credential configuration and never fall back
to a desktop credential helper.

Future signing stages must use an explicitly selected identity in a dedicated
temporary keychain. The runner must import the credential before dispatch,
configure its key partition list, unlock it for the bounded run, perform a
signing smoke test, and remove it during cleanup. Make parsing must not call
`security find-identity`, and a release must not rely on the default login
keychain.

macOS TCC permission cannot be clicked or granted by the pipeline. Future
runtime validation must use one stable signed designated identity and an
internal stable path, and must reject a runner that has not been provisioned
for that identity. Ad-hoc re-signing, launching a candidate directly from a
removable volume, or changing the service bundle identity during validation is
forbidden.

The lifecycle performance sink binds to loopback by default. A hosted or
otherwise provisioned cross-VM matrix may opt into a wildcard bind explicitly
with `PARITY_SINK_BIND_ADDRESS=0.0.0.0`; ordinary unattended runs must not do
so. Performance and live-runtime matrices remain outside the phase-one
Nextflow graph.

All commands retain finite deadlines, but a deadline is only the last liveness
guard. Preflight prevention is required because a two-hour timeout around a GUI
dialog is still a failed unattended design.

## Failure Taxonomy And Retry Policy

Phase-one repository stages record their declared `source`, `test`, or `build`
class in the failure receipt. They do not yet infer a richer cause from command
output. The target taxonomy for migrated runtime, authority, and publication
stages adds:

- `artifact`: missing, corrupt, unsigned, wrong-platform, wrong-reference, or
  incomplete input/output;
- `host-capability`: unsupported toolchain, virtualisation, disk, socket, or
  runner configuration;
- `blocked-host-policy`: keychain, TCC, removable-volume, or interactive prompt
  risk;
- `runtime-infrastructure`: bounded XPC replacement, runtime startup, lock, or
  guest failure;
- `external-authority`: GitHub, Sonar, registry, key server, or network service;
  and
- `publication`: an idempotent external mutation that did not complete.

All phase-one repository stages have zero automatic retries. In the target
system, source, test, build, and artifact failures also do not retry
automatically; the operator fixes or replaces the bad input and resumes.
Runtime infrastructure and
external authority may use a small, recorded retry budget with bounded backoff
for specifically recognised conditions. Unknown failures do not retry.

The development-cycle stop rule remains normative: repeated attempts without
new evidence become a structured blocker rather than an endless rebuild loop.

## Evidence Contract

Phase one durably publishes the attempt manifest, console, Nextflow log, trace,
report, timeline, DAG, repository preflight receipts, and successful stage
receipts; a successful graph also publishes its pipeline summary. A failed
stage atomically persists its failure receipt, stage command, standard output,
standard error,
`.command.sh`, and `.command.run` below
`$PIPELINE_STATE_ROOT/failures/<session-uuid>/<stage>`. The Make wrapper copies
that session's failure tree into the attempt evidence directory as
`failures/`. Phase one does not emit an output-artifact manifest, JUnit export,
coverage report, or coverage-floor decision of its own. The fuller contract
below is required before runtime, package, and release migration.

In the target state, every task retains outside the disposable work directory:

- task name, Nextflow task hash, session ID, attempt, profile, host, start,
  finish, duration, and final classification;
- exact declared inputs and their content digests;
- command script and selected environment manifest with secrets redacted;
- stdout, stderr, exit status, signal, deadline, retry decision, and cleanup
  result;
- declared output paths, modes, sizes, content digests, signatures, and
  provenance;
- JUnit, Swift Testing summary, Go test result, coverage, sanitizer, parity,
  timing, and runtime logs where applicable; and
- links by digest to the immutable run manifest and prerequisite receipts.

The workflow also emits Nextflow trace, report, timeline, and rendered DAG
artifacts. Important evidence is copied to the durable evidence root rather
than relying only on `.nextflow` metadata or a task work directory. Future
GitHub wrappers must upload the same evidence bundle with `always()` semantics.

Evidence contains no private key, token, credential-helper response, registry
secret, or unredacted security command. Publication receipts record external
object identifiers and digests, not credentials.

## Profiles

Four profiles exist in phase one:

- `focused` runs explicitly selected source, functional, or build stages and
  automatically adds the same-repository source stage for every selected
  functional or build stage;
- `repository` runs the Compose source stage followed by its Swift-test,
  Go-test, and CLI-smoke stages;
- `stack` runs the declared source and functional/build stages independently
  across Compose and the related repositories; and
- `hosted-safe` currently selects the same non-runtime family-health graph as
  `stack`.

Neither `stack` nor `hosted-safe` is matched-stack, runtime, parity, package, or
release proof. The remaining profile descriptions in this section define the
migration target.

The `focused` profile is the implementation loop. It does not infer affected
functional work beyond adding the required same-repository source gate, and it
does not start the live runtime.

The `repository` profile runs the Compose source stage, Swift test, Go test,
and CLI smoke. Those stages validate their declared source inputs and commands;
they do not export coverage or reusable build products.

The target `stack` profile adds sibling targets and runtime contracts on a
capable local or self-hosted Mac.

The future `parity` profile adds the selected or complete Docker Compose parity
contract channel and retained performance evidence.

The future `sanitizer` profile runs ASan and TSan as independent consumers of the
appropriate build snapshot. A sanitizer failure does not erase ordinary unit
proof.

As migration continues, `hosted-safe` must remain limited to stages that do not
require nested Virtualization.framework guests, launchd/XPC ownership, private
signing credentials, or local TCC state. It cannot satisfy the full release
gate.

The future `release-candidate` profile runs the complete immutable graph through
package, demo, and authority but performs no external mutation.

The future `release` profile consumes a successful exact release-candidate manifest
and enables the explicit publication transaction. It cannot silently broaden a
focused, repository, hosted-safe, or stack run into a release.

## Operator Recovery Flow

Bootstrap is an explicit networked step. Normal runs use the already verified
launcher offline:

```sh
make pipeline-bootstrap
make pipeline-plan PIPELINE_PROFILE=repository
make pipeline PIPELINE_PROFILE=repository
make pipeline-status
```

The plan prints the selected profile, repositories, stages, state root, and
disabled terminal boundaries. It does not claim cache hits and does not build
or mutate external state. Each actual attempt prints its durable evidence
directory and stores its session UUID there.

After a source or test failure, the operator reads the retained console and
trace plus the attempt's `failures/` directory, fixes and commits the source in
its normal repository, then resumes the exact failed session:

```sh
make pipeline-resume PIPELINE_SESSION=<failed-session-uuid>
```

The changed process and its true dependants run; independent successful tasks
are reused by their content identities. The wrapper rejects an absent or
malformed UUID and never invokes a bare `-resume`.

After a phase-one host failure, the operator repairs the host and resumes the
same session. Once external-authority stages are migrated, the equivalent flow
will wait for or repair the authority before resuming. No source snapshot is
changed and independent functional tasks remain reusable.

After interruption, the operator resumes the exact recorded session. Nextflow
applies its normal cache validation while the wrapper reacquires the single
state-root lock. The operator never repairs cache metadata by hand. Explicit
missing-output and corrupt-output recovery tests remain future acceptance
work, so phase one does not claim those cases as proved.

Future publication recovery must first read the external transaction journal,
verify the immutable package digest, and query actual GitHub and Homebrew state.
It must perform only missing idempotent mutations and refuse divergent external
state.

## GitHub Actions Integration

This section is the future remote-integration design. Phase one changes no
GitHub Actions workflow.

Each workflow becomes a thin profile dispatcher around the same pinned
Nextflow entry point used locally. GitHub selects source authority, runner
profile, and terminal boundary; it does not reproduce commands in YAML.

Self-hosted jobs restore the durable session and content cache for the exact run
manifest, run preflight, and invoke resume. They upload evidence regardless of
conclusion. Hosted jobs select `hosted-safe` and cannot claim live runtime or
release proof.

Cancellation remains safe before publication because successful task artifacts
and cache metadata are durable. Publication uses a non-cancelling concurrency
group and an external transaction journal. Sonar and other mutable authorities
run after functional evidence and remain independently retryable.

## Migration Path

Migration is incremental and must not require a second broad validation loop.

First, freeze existing checkpoint roots as read-only historical evidence.
Prohibit new `carried_forward` metadata and document that old stamps are not
accepted by the new graph.

Second, add the pinned Nextflow launcher, configuration, repository and tool
receipts, preflight, evidence writer, and a small graph around existing source,
build, and non-runtime functional commands. That phase is implemented here;
comparison with the existing repository gate remains the closeout proof. Do not
change test semantics during this step.

Third, make build products explicit immutable artifacts and have test stages
consume them without rebuilding. Add kill-and-resume, missing-output,
corrupt-output, concurrent-resume, dirty-source, and scoped-invalidation tests.

Fourth, move sibling target stamps and the 65 parity target loop into mapped
Nextflow tasks. Keep the existing Make and shell targets as adapters until the
new graph has demonstrated exact reuse and equivalent results.

Fifth, integrate runtime staging and unattended preflight. Reuse the existing
runtime lock, marker protection, service-input localisation, deadlines, and
signal cleanup. Add tests for runtime lock contention, XPC replacement,
external-volume rejection, locked keychain, absent signing identity, registry
credential prompting, and unprovisioned TCC state.

Sixth, split package, demo, external authority, and publication into separate
processes and migrate GitHub workflows to thin profile dispatchers. Exercise
publication recovery against a non-production fixture before allowing a real
release.

Finally, run both systems once against the same immutable release-candidate
inputs. Compare commands, artifacts, digests, tests, coverage, parity evidence,
runtime cleanup, and package output. Remove the bespoke outer checkpoint runner
and SHA stamps only after the Nextflow result is complete, reviewed, and
recoverable. Retain Make targets as documented developer commands unless they
become redundant for a separate reason.

Phase one is complete when an injected downstream defect fails one stage, an
exact-session corrected resume reuses independent upstream proof without
metadata editing, immutable source checks execute successfully from the
internal volume, failed work is diagnosable from durable history, and every
implemented profile is bounded and noninteractive.

The complete migration is finished only when the same properties also cover
matched runtime, parity, sanitizer, package, demonstration, external authority,
and publication stages, with reusable build artifacts and all prompt-prone host
capabilities proved before expensive work.
