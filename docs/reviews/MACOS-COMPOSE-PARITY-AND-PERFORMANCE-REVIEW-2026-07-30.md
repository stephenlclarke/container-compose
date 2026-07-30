# macOS Docker Compose Parity and Performance Review

Reviewed 30 July 2026 against `main` at
`8f7f56ec16998df79f456d5c93d5ace4e23cf060`.

## Scope and Evidence

This is a documentation-only assessment. It changes no Swift, Go, shell,
workflow, or product behavior. The review used:

- the current [parity ledger](../../STATUS.md) and its executable-target
  references;
- [the build and validation policy](../../BUILD.md);
- [the stable architecture boundary](../../DESIGN.md);
- the latest successful `main` CI run, including its successful
  [SonarQube scan](https://github.com/stephenlclarke/container-compose/actions/runs/30513608967);
- the public [SonarQube Cloud project](https://sonarcloud.io/summary/new_code?id=stephenlclarke_container-compose2),
  queried on 30 July 2026.

The review does not recategorize a platform-specific Docker behavior as a
Compose defect. It does treat every missing behavior that Docker Compose can
exercise in local macOS mode as a parity gap until an oracle proves it.

The [implementation update](#implementation-update) at the end records the same-day code, runtime-validation, SonarQube, and controlled parity follow-through without rewriting the original documentation-only baseline.

## Conclusion

The project has a substantial and well-tested Compose surface, but it does
not yet have 100% macOS Docker Compose parity or a complete comparable-performance
gate. Those outcomes are now first-class project goals in
[STATUS.md](../../STATUS.md#project-goal-macos-docker-compose-parity-and-performance),
not aspirational statements.

The most consequential gaps are network-scoped service identity and aliases,
runtime semantics that require missing host primitives, distinct Docker
logging and volume-driver behavior, and the incomplete same-host performance
matrix. The current architecture's
`ComposeRuntimeSPI` boundary remains the correct containment point: runtime
primitive work must not be worked around by silently changing Compose policy.

## Findings and Required Follow-up

| ID | Priority | Finding | Required next implementation phase | Done when |
| --- | --- | --- | --- | --- |
| PARITY-001 | P1 | The ledger has partial service/runtime, network, volume, build, deploy, and model surfaces. The CLI reports 42 fully supported commands, 4 partial commands, 261 fully supported long options, and 2 partial options. | Make every macOS-exercisable gap either an executable behavior-level oracle or an explicit, evidenced platform non-goal; retain the current runtime/Compose ownership split. | No project-owned partial or unsupported macOS surface remains, and each green row has an oracle. |
| NET-002 | P1 | Container-facing, network-scoped DNS is absent. That blocks service/container-name resolution, `networks.aliases`, `run --use-aliases`, dynamic address reconciliation, and complete link semantics. | Deliver the generic network identity primitive before adding a Compose-layer workaround. Follow the existing NET-201 through NET-205 plan. | Shared-network names and aliases update deterministically across create, scale, recreate, connect, disconnect, and teardown, with Docker reference fixtures. |
| PERF-003 | P1 | **Partial:** the live bridge lifecycle now records raw monotonic samples, JUnit, fingerprints, and medians with a 10× timeout/regression guard, but the representative single-service and 10/50-service startup, logs, sync, build-context, and teardown matrix is still absent. Bridge `up` is also 7.30× slower in the latest controlled run, so the product goal is not met even though the executable guard passes. | Complete and gate the same-host macOS comparator, add P95 reporting, and optimize measured paths until they are comparable to or faster than Docker Compose outside an explicit noise band. | Every representative path has reproducible median/P95 evidence and is comparable to or faster than the pinned reference. |
| ARCH-004 | P2 | The matched four-repository runtime stack is intentionally coupled, while the support ledger is principally prose. This makes runtime-capability drift expensive to detect. | Promote the existing typed capability-manifest work (`ARCH-103` and `ECO-606`) so the runtime reports the exact primitive and version expected by each Compose capability. | Compatibility checks and the parity ledger consume one machine-readable capability source; no behavior is inferred from version guessing. |
| SQ-005 | Complete | Signed refactor `98f2a7139b2e99a60cabdc8ca2d7190c33b7e994` extracted task creation, signal attachment, and result collection into named helpers without suppressing `swift:S3087` or weakening cancellation. | Keep the focused signal/cancellation regressions and zero-issue analyzer result in the final gate. | Complete: 25 focused preflight tests pass. Fresh branch analysis `39c6e9ff-0a90-4cd5-9b59-ed466f5fbdea` processed successfully with zero scanner warnings; SonarCloud rejects short-branch metric, issue, and quality-gate API reads on the current organization plan, so the hosted pull-request check remains the final gate authority. |

The related critical-review items were initially prioritized as `PARITY-506` P1, `PERF-607` P1, and `SQ-013` P1 in [the stack review](CONTAINER-STACK-CRITICAL-REVIEW-2026-07-24.md). `SQ-013` is now complete; the parity and performance items remain open.

## Parity Boundary

The 100% target means observable local macOS behavior, rather than parser
coverage alone. It includes command and option discovery, project loading and
rendering, accepted inputs, output, errors and exit statuses, lifecycle
effects, resource state, and behavior under repeated reconcile operations.

The target excludes only behavior Docker Compose cannot exercise in local
macOS mode, such as Windows-only settings and Docker Swarm scheduling. Those
items remain visible in the ledger as platform or product non-goals. A
missing primitive in the supported runtime stack is not an exemption.

## Performance Gate Specification

The performance gate must compare the pinned Docker Compose reference and
`container compose` on the same Mac, using identical images, fixtures,
isolated state, and warm/cold mode. It must publish raw samples plus median
and P95 values for:

- one-service startup to readiness;
- 10-service and 50-service startup to readiness;
- attached and detached log delivery;
- `develop.watch` initial sync and an incremental sync;
- local build-context transfer; and
- `down --volumes --remove-orphans` teardown.

A result is comparable when it is not materially worse than Docker Compose
outside a documented measurement-noise band. A result is better when its
relevant median and P95 are no higher. Any benchmark change must preserve the
reference version, host configuration, sample count, image digests, and
fixture state in its artifact so a later result can be reproduced.

## Architecture Assessment

The current separation is sound: `compose-go` owns Compose semantics, Swift
owns Docker-shaped orchestration policy, `ComposeRuntimeSPI` keeps policy
independent of Apple packages, and adapters translate to the matched stack.
The review found no basis for a broad architecture rewrite.

The specific design constraint is to keep missing runtime primitives below
the SPI boundary. In particular, DNS, shared-sandbox, logging-driver,
volume-driver, and Docker API-socket gaps need generic runtime contracts;
accepting Compose syntax and then approximating it with local metadata would
make the parity ledger misleading. The source-level `SQ-005` debt is now
closed by named preflight helpers with the existing signal, cancellation, and
failure behavior preserved.

## SonarQube Snapshot

The SonarQube Quality Gate is currently **OK** and the latest `main` CI scan
succeeded. New-code conditions are green: reliability, security, and
maintainability ratings are A; new coverage is 82.8% against an 80%
threshold; new duplication is 0.2% against a 3% threshold; and security
hotspots are 100% reviewed. Overall measures show 0 bugs, 0 vulnerabilities,
A reliability/security/maintainability ratings, 82.9% coverage, and 0.4%
duplicated lines.

At the initial documentation-only snapshot, that was not a zero-debt interpretation of “all metrics green”: the project still had one open `swift:S3087` code smell with 15 minutes of estimated remediation. Documentation alone could not close it, so `SQ-005` and `SQ-013` made source remediation a required implementation-phase acceptance criterion rather than masking it with a suppression or a won't-fix status. The implementation update below records that closure.

## Documentation-Phase Outcome

The initial documentation-only phase established the measurable north star, made the performance comparator a P1 requirement, promoted behavior-level parity evidence to a P1 requirement, recorded the exact SonarQube debt, and left production implementation unchanged. Its proposed next phase began with `SQ-005` and `PERF-003`, followed by parity gaps in runtime-primitive order beginning with network identity.

## Implementation Update

Same-day implementation continued after the documentation-only baseline:

- `98f2a7139b2e99a60cabdc8ca2d7190c33b7e994` closes `SQ-005`/`SQ-013` through named preflight task and signal helpers. The focused 25-test preflight set and full test suite preserve cancellation, signal-proxy ordering, bounded diagnostics, and child reaping.
- `36d81f70402c0d203bde8f7c8d57bb574a689e52`, `d6b47233012a31be559c91f8e51f7a579a704736`, and `d95194e4f573de9716316b4dc4c287f16e6deb2e` implement `network_mode: bridge`, avoid unreferenced project resources, and remove the release-build async-`inout` watch crash.
- `9a95ec8cc5a84e15a187ff20ccf948e9ac14bfe9` serializes cooperating host runtime users, accepts a retained exact init-image archive, and isolates marker-protected app state. `4a2e0003496c9f96afcc0b3f3d54124ebc09b25b` adds one bounded API-readiness restart, one idempotent interrupted image-pull retry, and delete postcondition verification without blindly replaying deletion.
- A controlled run passed all 62 maintained Docker Compose parity targets in 1,024.25s against Docker Compose 5.3.1 and Docker Engine 29.2.1 on Mac17,9/macOS 26.5.2. Bridge `up` medians were 0.151s reference and 1.101s candidate (7.30×); `down` medians were 10.179s and 5.969s (0.59×). A separate 10-repetition stress run measured 6.78× and 0.58× respectively.
- Two SwiftNIO event-loop shutdown warnings were retained from image-volume builder teardown. They did not fail a build or assertion, but remain cleanup evidence rather than being filtered from the record.
- CodeQL is manually disabled at the owner's request while its required context remains configured. No missing CodeQL run is counted as green, and the workflow must remain off until explicitly re-enabled.

The implementation moves the goal forward but does not close it. `PERF-003` remains P1 because bridge startup is materially slower and the broader representative matrix is absent; `PARITY-001`, `NET-002`, and `ARCH-004` likewise remain open.
