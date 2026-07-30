# Pull Request: Isolate macOS Container Runtime Validation

## Summary

- Serialize cooperating Compose and Current-release runtime users with one per-user advisory lock.
- Reuse a retained init-image archive from the exact matched runtime source.
- Require a real API round trip after starting the matched runtime and recover once from a transient XPC startup failure.
- Retry only idempotent image pulls after a typed recursive interruption.
- Accept an interrupted container delete only after direct discovery proves the target is absent.
- Preserve fixture failures, raw timings, and exact runtime fingerprints without parity-test retries.

See the companion [issue handoff](ISSUE-container-runtime-validation-reliability.md).

## Intended Review Delta

Apply these signed commits:

- `9a95ec8cc5a84e15a187ff20ccf948e9ac14bfe9` — `fix(ci): isolate container runtime validation`
- `4a2e0003496c9f96afcc0b3f3d54124ebc09b25b` — `fix(runtime): recover interrupted XPC operations`

## Motivation and Context

Isolated app roots did not prevent other self-hosted workflows from replacing Container's stable launchd/XPC services during the 62-target parity suite. A preflight fingerprint could identify a changed API server before a fixture started, but it could not prevent another runner from accepting work after that observation. The run needed a host-wide coordination boundary for every participant and honest documentation for non-participants.

The same live runs showed that transport interruption is not one universal retry signal. Pull is idempotent and safe to repeat once. Delete may already have completed, so its postcondition must be checked instead of replaying the operation. Runtime startup needs both a successful command exit and a working API, while a persistent or unrelated error must remain visible.

## Code Map

- `Tools/ci/container-runtime-lock.sh` owns the reentrant `lockf` boundary, timeout validation, and default per-user lock path.
- `scripts/run-with-container-runtime.sh` acquires the lock, cleans only a marker-protected app root, loads a retained init archive when supplied, verifies API readiness, and performs one bounded start recovery.
- `Makefile` forwards retained-archive and parity-evidence settings into the harness.
- `.github/workflows/prebuilt-binaries.yml` acquires the same lock before the Current VHS runtime workflow.
- `Sources/ComposeContainerRuntime/ContainerImageAdapter.swift` recognizes typed recursive interruption and retries one image pull.
- `Sources/ComposeCore/ComposeOrchestratorMountsContainersVolumes.swift` verifies absence after an interrupted delete without retrying it.
- `Tools/ci/test_run_with_container_runtime.py` covers archive loading, startup recovery, and lock serialization.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` covers interrupted pull and delete outcomes, including recursive causes and failed postcondition discovery.

## Validation

```console
HAWKEYE_AUTO_INSTALL=1 make check
make test
python3 Tools/ci/test_run_with_container_runtime.py
bash -n Tools/ci/container-runtime-lock.sh scripts/run-with-container-runtime.sh
shellcheck Tools/ci/container-runtime-lock.sh scripts/run-with-container-runtime.sh
CONTAINER_COMPOSE_LIVE=1 \
  PARITY_REPETITIONS=10 \
  PARITY_EVIDENCE_DIR=.build/parity/host-namespace-interrupted-delete-fix-rerun-2 \
  make docker-compose-host-namespaces-parity
CONTAINER_COMPOSE_LIVE=1 \
  PARITY_REPETITIONS=3 \
  PARITY_EVIDENCE_DIR=.build/parity/full-4a2e0003-controlled \
  make docker-compose-parity
```

Results:

- `make check` passes.
- The full unit gate passes 1,277 Swift tests in 46 suites plus all Go packages.
- Four focused Python harness/lock tests pass.
- The 10-repetition bridge stress run completes in 241.31s with Docker/candidate `up` medians of 0.156s/1.060s (6.78×) and `down` medians of 10.181s/5.924s (0.58×).
- The controlled full suite passes all 62 maintained targets in 1,024.25s real time, 257.89s user time, and 327.29s system time, with a 4,239,622,144-byte maximum resident set size.
- Its three-repetition bridge comparator records 0.151s/1.101s Docker/candidate `up` medians (7.30×) and 10.179s/5.969s `down` medians (0.59×).
- Raw TSV, JUnit, exact fingerprints, matrices, and logs are retained under the two named ignored evidence directories.
- The exact retained init archive for Containerization `971fc7e5e27467ebd6227e1ae54f3e5c23de87b4` has SHA-256 `51cd9ab90c4d12060701fa7ade5ebbc7f097870c1f5157a67de3d0124ac56d4d`.

The 7.30× `up` result passes the explicit 10× timeout/regression guard but does not meet the product goal of comparable or better performance. The broader median/P95 performance matrix remains open.

## Compatibility and Risk

- The advisory lock protects only workflows that acquire the same path. A unique per-job override or a non-cooperating repository defeats host serialization.
- App-root isolation still isolates data and cleanup, but not stable per-user service labels.
- Startup recovery is limited to two total attempts and requires API readiness.
- Pull recovery is limited to one typed recursive interruption; arbitrary errors are not retried.
- Delete recovery never replays deletion and cannot succeed when discovery fails or the target remains.
- Parity fixtures themselves are not retried, so timeouts and functional failures remain authoritative.
- The controlled run temporarily quiesced a non-cooperating devcontainer runner and restored its launchd listener/worker immediately afterward.
- Two SwiftNIO shutdown warnings remain visible from Builder teardown; they did not fail the affected build or parity target.
- The change does not resolve lower-runtime delayed-reply continuation or launchd ownership work tracked separately as `XPC-304`.
- CodeQL is manually disabled at the owner's request. The required context remains configured and no missing result is counted as green.

## Checklist

- [x] Signed Conventional implementation commits
- [x] Focused lock, archive, startup, pull, and delete tests
- [x] Complete unit and source gate
- [x] 10-repetition focused stress evidence
- [x] Controlled 62-target parity evidence with timings and fingerprints
- [x] Matching issue and pull-request handoffs
- [x] Non-cooperating runner restored after the controlled window
- [ ] Draft pull-request publication and connector review
- [ ] Exact-head CI, Quality, Documentation, and SonarQube
- [ ] Exact-revision CodeQL after the owner explicitly re-enables the workflow
