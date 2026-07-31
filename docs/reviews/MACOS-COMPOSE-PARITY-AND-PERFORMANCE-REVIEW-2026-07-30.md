# macOS Docker Compose Parity and Performance Review

Reviewed through 31 July 2026; baseline `main` was
`8f7f56ec16998df79f456d5c93d5ace4e23cf060`.

## Scope and Evidence

This review began as a documentation-only assessment. It is now the current
evidence-backed assessment and records later implementation and measurement
updates without treating them as proof of full parity. It uses:

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

Named-network service identity, aliases, and source-scoped links are now
complete on the supported stack. The most consequential remaining gaps are
runtime semantics that require missing host primitives, distinct Docker
logging and volume-driver behavior, and the incomplete same-host performance
matrix. The current architecture's
`ComposeRuntimeSPI` boundary remains the correct containment point: runtime
primitive work must not be worked around by silently changing Compose policy.

## Findings and Required Follow-up

| ID | Priority | Finding | Required next implementation phase | Done when |
| --- | --- | --- | --- | --- |
| PARITY-001 | P1 | The ledger has partial service/runtime, network, volume, deploy, and model surfaces. The CLI reports 44 fully supported commands, 2 partial commands, 262 fully supported long options, and 1 partial option. | Make every macOS-exercisable gap either an executable behavior-level oracle or an explicit, evidenced platform non-goal; retain the current runtime/Compose ownership split. | No project-owned partial or unsupported macOS surface remains, and each green row has an oracle. |
| NET-002 | Complete | The supported runtime now provides container-facing, network-scoped DNS. Service/container names, `networks.aliases`, scaled answers, `run --use-aliases`, recreate/address reconciliation, source-scoped `links`, and dynamic `external_links` pass live Docker Compose oracles. | Keep the generic primitive below `ComposeRuntimeSPI`, retain collision/lifecycle tests, and converge the fork implementation upstream where possible. | Complete on the supported stack: shared-network names and aliases update deterministically across create, scale, recreate, connect, disconnect, and teardown. |
| PERF-003 | P1 | **Partial:** bridge, service-discovery, links, and archive-copy workloads record same-host timings. `make docker-compose-performance-matrix` adds raw monotonic, fingerprinted median/P95 evidence for warm-image detached 1/10/50-service startup and teardown. Its one-repetition debug diagnostic is slower than Docker at 10 and 50 services; attached/detached logs, `develop.watch` initial/incremental sync, and build-context transfer are still absent. | Complete and gate the remaining same-host comparator lanes, then optimize measured paths until they are comparable to or faster than Docker Compose outside an explicit noise band. | Every representative path has reproducible median/P95 evidence and is comparable to or faster than the pinned reference. |
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
- `443ca69b1a55ac5331c5f7d341a87c277b1c02bb` adds named-network service/container names, aliases, scaled answers, one-off aliases, and attachment-lifecycle parity. `acb289fa36400b7931413952b57fdd68e08845b6` and `6235cc589c235849a9a34a18335297630043499f` add source-scoped legacy and dynamic external link aliases.
- `62da66f0f106c165f07ea22a92a4e0cf598ee012` starts dependency-independent services concurrently within bounded, dependency-safe layers. Final service-discovery startup was 13.0% faster than the 4.965816s pre-optimization candidate baseline, but remains materially slower than Docker.
- Validation found and fixed three additional defects: `9d2f29f6038fb6a20d61a877beff26e7b84a8768` gives the runtime exporter sole ownership of the commit archive destination, `4e8be34bab9ee1b909e46e81cd077da9c00d49f9` corrects the default-network service-alias oracle, and `e969e4796690f88425488ad2b9ca9f795ca4f9c1` makes the health-wait live target standalone by preparing its exact fixture image.
- One uninterrupted controlled run at `e969e4796690f88425488ad2b9ca9f795ca4f9c1` passed all 62 maintained Docker Compose parity targets in 1,152.03s against Docker Compose 5.3.1 and Docker Engine 29.2.1 on Mac17,9/macOS 26.5.2. Bridge `up` medians were 0.153s reference and 1.228s candidate (8.01×); `down` medians were 10.178s and 5.916s (0.58×).
- Two SwiftNIO event-loop shutdown warnings were retained from image-volume builder teardown. They did not fail a build or assertion, but remain cleanup evidence rather than being filtered from the record.
- CodeQL is manually disabled at the owner's request while its required context remains configured. No missing CodeQL run is counted as green, and the workflow must remain off until explicitly re-enabled.

The implementation moves the goal forward but does not close it. `NET-002` is complete on the supported stack. `PERF-003` remains P1 because measured startup and archive paths are materially slower, the current lifecycle run is diagnostic rather than release-grade, and logs/watch/build lanes remain absent; `PARITY-001` and `ARCH-004` likewise remain open.

## Latest Timing Detail

These timings come from the uninterrupted 62-target run at
`e969e4796690f88425488ad2b9ca9f795ca4f9c1`. The run used debug builds, exact
matched runtime pins, the same Mac and prepared fixture images for both
engines, and Docker Compose 5.3.1 as the reference. Service-discovery, links,
and bridge values are three-repetition medians. Candidate/reference ratios
greater than 1 are slower than Docker.

### Named-Network Service Discovery

| Operation | Docker median (s) | container-compose median (s) | Candidate/reference |
| --- | ---: | ---: | ---: |
| Alias teardown lookup | 0.168972 | 0.653365 | 3.87× |
| Container-name lookup | 0.113065 | 0.650316 | 5.75× |
| Explicit-alias lookup | 0.171094 | 0.660519 | 3.86× |
| One-off alias lookup | 0.171547 | 0.646868 | 3.77× |
| One-off alias start | 0.271882 | 1.295355 | 4.76× |
| Recreate with static address | 1.392856 | 2.579256 | 1.85× |
| Service-name lookup | 0.162555 | 0.644815 | 3.97× |
| Shared-alias lookup | 0.115536 | 0.640230 | 5.54× |
| Project startup | 0.490196 | 4.317872 | 8.81× |

The final 4.317872s candidate startup median is 13.0% lower than the
4.965816s pre-optimization baseline. Functionality is green; comparable
startup performance is not.

### Source-Scoped Links

| Operation | Docker median (s) | container-compose median (s) | Candidate/reference |
| --- | ---: | ---: | ---: |
| External target absent lookup | 0.167918 | 0.647981 | 3.86× |
| External alias hosts | 0.170173 | 0.646394 | 3.80× |
| External backend create | 0.166626 | 0.706189 | 4.24× |
| External backend lookup | 0.112197 | 0.640979 | 5.71× |
| External post-remove lookup | 0.168986 | 0.662784 | 3.92× |
| External remove | 0.226763 | 0.224007 | 0.99× |
| External secondary-network create | 0.166636 | 0.707185 | 4.24× |
| External secondary-network lookup | 0.165299 | 0.660038 | 3.99× |
| Post-readdress lookup | 0.163896 | 0.644708 | 3.93× |
| Readdressed link hosts | 0.166448 | 0.601539 | 3.61× |
| Readdressed link isolation | 0.168166 | 0.648277 | 3.85× |
| Scaled link hosts | 0.113712 | 0.650148 | 5.72× |
| Scaled link isolation | 0.171024 | 0.645611 | 3.77× |
| Scaled link lookup | 0.167665 | 0.649442 | 3.87× |
| Project startup | 0.603993 | 5.209138 | 8.62× |
| Target readdress | 1.354947 | 2.485010 | 1.83× |

### Archive Copy

The `cp` oracle currently records one bounded operation timing per direction
and metadata fixture rather than a multi-sample median. All content and
metadata assertions passed.

| Operation | Docker (s) | container-compose (s) | Candidate/reference |
| --- | ---: | ---: | ---: |
| Stdin content | 0.074214 | 0.586646 | 7.90× |
| Stdin hard links | 0.084167 | 0.585171 | 6.95× |
| Stdin metadata | 0.170029 | 2.542555 | 14.95× |
| Stdout content | 0.123555 | 0.579463 | 4.69× |

### Built-In Bridge Lifecycle

| Operation | Docker median (s) | container-compose median (s) | Candidate/reference |
| --- | ---: | ---: | ---: |
| `network_mode: bridge` up | 0.153 | 1.228 | 8.01× |
| `network_mode: bridge` down | 10.178 | 5.916 | 0.58× |

The aggregate 1,152.03s suite wall time is validation evidence, not a
representative performance benchmark. `PERF-003` remains open until the
specified median/P95 matrix is implemented and every material candidate
regression is removed.

### Lifecycle Matrix Diagnostic

The 31 July one-repetition lifecycle matrix run used the matched stack but a
debug candidate build, so it establishes neither a release baseline nor a
comparable-performance result. It retained raw TSV, JUnit, a generated matrix,
and fingerprints in `.build/parity/performance-matrix-smoke/`.

| Fixture | Docker (s) | container-compose (s) | Candidate/reference |
| --- | ---: | ---: | ---: |
| 1-service startup | 0.191 | 1.487 | 7.77× |
| 10-service startup | 0.523 | 6.644 | 12.71× |
| 50-service startup | 2.093 | 30.745 | 14.69× |
| 1-service teardown | 1.256 | 1.931 | 1.54× |
| 10-service teardown | 1.528 | 15.915 | 10.42× |
| 50-service teardown | 2.637 | 68.944 | 26.14× |

The diagnostic validates the lifecycle lane and exposes the scaling work: the
10× material-regression guard would reject the four 10/50-service results.
The next authoritative result must use a matched non-debug bundle, the normal
sample count, and the still-missing logs, watch, and build-context lanes.
