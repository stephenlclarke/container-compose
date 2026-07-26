# Pull Request

## Summary

- Orchestrates service-level `pre_start` helpers using existing Apple container
  primitives.
- Completes lifecycle-managed foreground `run` for interactive and
  non-interactive one-offs.
- Preserves Docker-compatible helper ordering, failure gating, detach behavior,
  cleanup, signals, automatic removal, and exact process exit status.
- Keeps the change in the Compose layer; no runtime fork or package-pin change
  is required.
- Adds focused unit coverage and a live Docker Compose V2 parity fixture.
- Repairs incomplete restored SwiftPM checkouts before CI edits the local stack
  dependency.
- Updates generated help, README, the parity ledger, and the current critical
  review.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Lifecycle hook normalization and the underlying runtime operations were already
available, but `container-compose` rejected `pre_start` and did not use the
supported runtime lane's init-process reattach primitive for interactive
foreground `run`. Diagnostics incorrectly described these as missing Apple
primitives.

Docker Compose V2 implements `pre_start` as Compose-owned orchestration: it
creates an ephemeral helper with the service container's mounts and networks,
waits for it, removes it, and gates startup on its result. Keeping the same
boundary makes the change minimally invasive and suitable for upstream review.

## Commit Tracking

- Compose implementation and unit tests:
  `ec3a0078a72611d1f7cf4717c28b8232d33e3a5e`
  (`feat(lifecycle): complete service and run hooks`).
- Compose V2 parity fixture:
  `498a5381c7052c9e06f9887896b590a81c482c6e`
  (`test(lifecycle): add Compose v2 parity fixture`).
- Hosted CI cache repair and regression coverage:
  `835b3c8a73b1397681de2d89267b58fa0bbebff2`
  (`fix(ci): repair incomplete SwiftPM caches`).
- Connector-review follow-up for dependency helper image preparation:
  `06213c015179ff5dae11d86d43f36f09c7f23479`
  (`fix(lifecycle): prepare dependency hook images`).
- `apple/container` code commit: not required.
- `apple/containerization` code commit: not required.
- Package-pin change: not required.

## Implementation Details

### `pre_start`

- `Sources/ComposeCore/ComposeOrchestratorPreStart.swift` owns helper image
  planning, service-level start convergence, ephemeral helper creation,
  execution, status handling, cleanup, and bounded deterministic names.
- Helpers inherit service environment, networks, platform, and target mounts
  through `volumes_from`; hook environment, image, user, working directory, and
  privileged values override the inherited defaults.
- Explicit helper images participate in service runtime image preparation and
  pull-policy handling without appearing in direct `pull` or `config --images`
  projections.
- Helpers execute sequentially against the lowest-numbered stopped target.
  Startup proceeds only after all helpers return zero.
- A paused Apple container is treated as Docker's started state for
  service-level convergence.
- `up`, `start`, and dependency starts share the same helper path. An
  idempotent `up`, scale while any replica remains started, and `restart` do not
  rerun `pre_start`.
- `compose run` applies the default missing-image preparation to explicit
  dependency hook images before it creates any dependency container.

### Foreground `run`

- Lifecycle-managed interactive one-offs start detached, execute `post_start`,
  and reattach through the supported runtime's init-process stream.
- A one-shot signal gate runs `pre_stop` before the direct stop fallback.
- Detach-key completion is distinguished from process exit so `run --rm`
  retains runtime automatic removal after detach.
- Non-interactive one-offs continue to drain logs and wait, then run
  `pre_stop` and perform explicit cleanup where required.
- `ComposeRunExitError` carries only the one-off command status to
  ArgumentParser's `ExitCode`; orchestration and hook failures keep their
  original errors and diagnostics.

### Validation and Help

- Lifecycle validation continues to reject incomplete hooks and Docker
  Compose's unsupported `pre_start.per_replica: true`.
- `run` and `up` help now report only the independent container-facing DNS
  alias gap.
- `STATUS.md` records lifecycle hooks as complete for the supported macOS lane.

## Docker Compose Compatibility

The checked-in fixture compares against Docker Compose V2 5.3.1 and then runs
the same contract through the matching Apple Current runtime:

- helper image and service-image fallback;
- service environment plus hook override;
- user, working directory, mount, and network inheritance;
- sequential ordering and failure status;
- helper cleanup;
- idempotent `up`, scale, `restart`, and stop/start semantics;
- foreground `post_start` and `pre_stop`;
- interactive output, detach keys, and automatic removal;
- direct one-off exit status `7` without a spurious `Error:` line.

Docker Compose V2 rejects `pre_start.per_replica: true`; it is deliberately not
implemented as a portability extension.

## Validation

Focused lifecycle and exit-code coverage:

```console
swift test --disable-automatic-resolution --enable-code-coverage --filter \
  'preStart|runForeground|runInterruption|runReattachesInteractive|interactiveRunDetachKeys|interactiveLifecycleAttachment|foregroundLifecycleGuards|ComposeRunExitCode'
```

Result: 23 focused tests passed.

Full repository gates:

```console
make coverage-check
make check
git diff --check
bash -n Tools/parity/check-compose-lifecycle-hooks.sh
shellcheck Tools/parity/check-compose-lifecycle-hooks.sh
```

Results:

- 1,218 Swift tests passed.
- Swift coverage: 92.14%, increased from the 92.10% main baseline.
- Go coverage: 89.88%.
- Release/CI tooling, Markdown, stack consistency, license, SwiftLint, and
  SwiftFormat checks passed.
- The CI tooling suite increased from 14 to 16 tests.

Live parity:

```console
CONTAINER_COMPOSE_LIVE=1 \
CONTAINER_COMPOSE_CONTAINER=/opt/homebrew/opt/container-current/bin/container \
Tools/parity/check-compose-lifecycle-hooks.sh --strict
```

Result: Docker Compose V2 5.3.1 and the matching Apple Current runtime passed
the complete lifecycle contract with no leftover fixture resources.

Sonar:

```console
SONAR_QUALITYGATE_WAIT=false make sonar-scan
```

The branch analysis was accepted and processed successfully. The locally
available analysis token cannot read quality-gate or issue endpoints; the
repository-bound PR Sonar check remains blocking and must be green with all
actionable findings resolved before merge.

The first hosted runtime-validation attempt restored SwiftPM workspace metadata
without five referenced checkout manifests and failed before compilation.
`Tools/ci/use-stack-container.sh` now runs `swift package resolve` before
`swift package edit`; focused fake-Swift regression coverage proves repair
precedes graph editing and that a missing container checkout still fails
closed.

The `chatgpt-codex-connector` review identified a clean-host dependency edge
case after the initial PR head. The focused follow-up reuses
`applyPullPolicy(nil, ...)` for `compose run` dependencies and adds a regression
that proves helper-image preparation fails before any container is created.

## Compatibility

- Only macOS-feasible behavior is implemented. No Windows behavior is added.
- Linux guest commands and semantics that the Apple macOS runtime can execute
  are included.
- The supported fork lane already has the interactive init-process stream
  primitive. Stock Apple builds without that capability remain unsupported for
  interactive lifecycle-managed `run`.
- No public Compose syntax is changed.
- No `apple/container`, `containerization`, or package-reference change is
  included.

## Remaining Risks

- Container-facing DNS aliases remain unavailable and are independent of
  lifecycle hooks.
- Interactive lifecycle behavior depends on runtime capability negotiation
  until the reattach primitive converges upstream in `apple/container`.
- Docker Compose may change undocumented helper implementation details; the
  committed v5.3.1 parity contract protects user-visible behavior.

## Documentation and Demo

- `README.md`, `STATUS.md`, and the 2026-07-24 critical review are current for
  this slice.
- The README VHS demo remains a live recording: commands are visibly typed and
  their real output is captured. This slice does not reintroduce replay or
  marker-only presentation.
- Slice-start Slack evidence:
  <https://xyzzytools.slack.com/archives/C0B1RNM8ZJ5/p1784974788901079>.

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is
  needed.
- [x] I updated relevant upstream docs and the current critical review.
- [x] This pull request is focused on one coherent lifecycle slice.
- [x] I used Conventional Commits in commit messages and the pull request
  title.
- [x] I signed every commit with a GitHub-supported signature method.
- [x] I added unit and Docker Compose V2 parity coverage.
- [x] I removed credentials, tokens, private keys, personal data, and private
  registry details from code, tests, logs, screenshots, and handoff docs.
