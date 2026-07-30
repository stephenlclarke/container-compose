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

## Conclusion

The project has a substantial and well-tested Compose surface, but it does
not yet have 100% macOS Docker Compose parity or a comparable-performance
gate. Those outcomes are now first-class project goals in
[STATUS.md](../../STATUS.md#project-goal-macos-docker-compose-parity-and-performance),
not aspirational statements.

The most consequential gaps are network-scoped service identity and aliases,
runtime semantics that require missing host primitives, distinct Docker
logging and volume-driver behavior, and the absence of an executable
same-host performance comparator. The current architecture's
`ComposeRuntimeSPI` boundary remains the correct containment point: runtime
primitive work must not be worked around by silently changing Compose policy.

## Findings and Required Follow-up

| ID | Priority | Finding | Required next implementation phase | Done when |
| --- | --- | --- | --- | --- |
| PARITY-001 | P1 | The ledger has partial service/runtime, network, volume, build, deploy, and model surfaces. The CLI reports 42 fully supported commands, 4 partial commands, 261 fully supported long options, and 2 partial options. | Make every macOS-exercisable gap either an executable behavior-level oracle or an explicit, evidenced platform non-goal; retain the current runtime/Compose ownership split. | No project-owned partial or unsupported macOS surface remains, and each green row has an oracle. |
| NET-002 | P1 | Container-facing, network-scoped DNS is absent. That blocks service/container-name resolution, `networks.aliases`, `run --use-aliases`, dynamic address reconciliation, and complete link semantics. | Deliver the generic network identity primitive before adding a Compose-layer workaround. Follow the existing NET-201 through NET-205 plan. | Shared-network names and aliases update deterministically across create, scale, recreate, connect, disconnect, and teardown, with Docker reference fixtures. |
| PERF-003 | P1 | `make docker-compose-parity` is a functional comparison suite; the repository has no executable Compose performance comparator or checked-in baseline. | Implement and gate a same-host macOS comparator for single-service and 10/50-service startup, logs, sync, build-context transfer, and teardown. Record medians, P95s, machine/OS, revisions, images, fixture state, sample count, and warm/cold state. | Every measured path is comparable to or faster than the pinned Docker Compose reference, outside an explicit noise band. |
| ARCH-004 | P2 | The matched four-repository runtime stack is intentionally coupled, while the support ledger is principally prose. This makes runtime-capability drift expensive to detect. | Promote the existing typed capability-manifest work (`ARCH-103` and `ECO-606`) so the runtime reports the exact primitive and version expected by each Compose capability. | Compatibility checks and the parity ledger consume one machine-readable capability source; no behavior is inferred from version guessing. |
| SQ-005 | P1 | SonarQube reports one open major code smell: `swift:S3087` at `Sources/ComposePlugin/ContainerPackageCompatibility.swift:379`, caused by nested closures in cancellation/signal preflight. | Extract task creation, signal attachment, and result collection into named, testable helpers without suppressing the rule or weakening cancellation semantics. | Focused preflight signal/cancellation tests pass and the open SonarQube code-smell count is zero. |

The related critical-review items are now prioritized as `PARITY-506` P1,
`PERF-607` P1, and `SQ-013` P1 in
[the stack review](CONTAINER-STACK-CRITICAL-REVIEW-2026-07-24.md).

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
make the parity ledger misleading. The one current source-level design debt
is `SQ-005`: the nested cancellation/signal closures should become named
helpers while preserving the existing tests and failure behavior.

## SonarQube Snapshot

The SonarQube Quality Gate is currently **OK** and the latest `main` CI scan
succeeded. New-code conditions are green: reliability, security, and
maintainability ratings are A; new coverage is 82.8% against an 80%
threshold; new duplication is 0.2% against a 3% threshold; and security
hotspots are 100% reviewed. Overall measures show 0 bugs, 0 vulnerabilities,
A reliability/security/maintainability ratings, 82.9% coverage, and 0.4%
duplicated lines.

That is not a zero-debt interpretation of “all metrics green”: the project
still has the one open `swift:S3087` code smell above, with 15 minutes of
estimated remediation. Documentation cannot honestly close that finding.
`SQ-005` and `SQ-013` make its removal a required implementation-phase
acceptance criterion rather than masking it with a suppression or a
won't-fix status.

## Documentation-Phase Outcome

This phase establishes the measurable north star, makes the performance
comparator a P1 requirement, promotes behavior-level parity evidence to a
P1 requirement, records the exact SonarQube debt, and leaves all production
implementation unchanged. The next phase should start with `SQ-005` and
`PERF-003`, then close parity gaps in runtime-primitive order beginning with
network identity.
