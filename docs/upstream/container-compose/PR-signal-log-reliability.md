# Pull request handoff: consume signal and log reliability fixes

## Summary

Pin Compose to the signed Container fork revision that ports the preferred signal wire-format correction and adds explicit log-tail and failed-client regressions. Add a committed Docker Compose V2 fixture that exercises the same foreground attach, tail, and persistent-log behavior against both runtimes.

The companion report is [ISSUE-signal-log-reliability.md](ISSUE-signal-log-reliability.md).

## Minimal Integration Boundary

- No Compose command or model semantics change.
- No Apple signal-number, log-tail, or writer-fanout behavior is duplicated in `ComposeCore`.
- Runtime source stays in the independently reviewable Container commit.
- Compose owns only immutable stack provenance, the Docker v2 oracle, release gates, and current documentation.

## Code Map

- `Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json`
  - pin the exact signed Container fork merge.
- `Tools/parity/fixtures/signal-log-reliability/compose.yaml`
  - defines the attach-signal, long-tail, multi-record, and client-disconnect
    workloads. The attached workloads wait for an explicit stdin handshake
    rather than assuming a cold installed plugin subscribes within a fixed
    sleep.
- `Tools/parity/check-compose-signal-log-reliability.sh`
  - runs the same fixture through Docker Compose V2 and the optional matched
    Apple runtime, releasing each attach workload through the client under
    test.
- `scripts/run-with-container-runtime.sh` and
  `Tools/ci/test_run_with_container_runtime.py`
  - build and install the matched init image before selecting it in the
    isolated runtime configuration, with a cold-store ordering regression.
- `Makefile`
  - exposes `docker-compose-signal-log-reliability-parity`.
- `README.md`, `STATUS.md`, `docs/upstream/APPLE-UPSTREAM-REVIEW.md`, and `docs/reviews/CONTAINER-STACK-CRITICAL-REVIEW-2026-07-24.md`
  - record the supported behavior and current upstream disposition.
- `docs/upstream/apple-container/ISSUE-1941.md` and `docs/upstream/apple-container/PR-1997.md`
  - provide the upstream issue/PR handoff pair.

## Runtime Commit Map

- `bb2438c1f1bee38d671bf9dd94f89f603f52041e` — `fix(process): encode signals by Linux name`
- `26cc778b80ef847ff0fbf75579675981e5982613` — `test(logs): cover tail and client-failure continuity`
- `221fafc24ebd19502f4553e0b5d38c14be3f2b22` — signed Container fork merge
- [stephenlclarke/container#29](https://github.com/stephenlclarke/container/pull/29) — signed fork integration pull request
- [apple/container#1997](https://github.com/apple/container/pull/1997) — preferred upstream signal correction
- [apple/container#2000](https://github.com/apple/container/pull/2000) — upstream long-tail correction with equivalent supported-fork behavior
- [apple/container#2009](https://github.com/apple/container/issues/2009) — dead-client fan-out report covered by the supported init-process output path

## Validation

```console
bash -n Tools/parity/check-compose-signal-log-reliability.sh
shellcheck Tools/parity/check-compose-signal-log-reliability.sh
docker compose -f Tools/parity/fixtures/signal-log-reliability/compose.yaml config
python3 -m unittest Tools.ci.test_run_with_container_runtime
make check
make coverage-check
make stack-consistency
make docker-compose-signal-log-reliability-parity
```

Completed locally on macOS arm64:

- Docker Compose V2 and the exact matched Apple runtime both forwarded
  `SIGINT`; the Linux service recorded the signal and exited 42.
- Both implementations returned the exact 3,009-byte single-record tail and
  two exact 801-byte multi-record tail lines.
- Both implementations retained the records before and after their attach
  clients were terminated. The client process trees were reaped before the
  second record existed, preventing a natural workload exit from satisfying
  the assertion.
- The isolated runtime wrapper ordering regression passed.
- 13 focused Compose attach/log adapter tests passed.
- 1,218 Swift tests in 41 suites passed.
- Swift line coverage was 92.13% against a 90% gate.
- Go statement coverage was 89.88% against an 85% gate.
- Exact-head
  [CI](https://github.com/stephenlclarke/container-compose/actions/runs/30193773406),
  [Quality](https://github.com/stephenlclarke/container-compose/actions/runs/30193773394),
  [CodeQL](https://github.com/stephenlclarke/container-compose/actions/runs/30193773396),
  and
  [DocC](https://github.com/stephenlclarke/container-compose/actions/runs/30193773392)
  passed for `b6547398e853035ced8d3023f0792996fa630f39`.
- The connector re-review of that exact head reported no major issues after
  the two P1 harness corrections received direct replies and were resolved.
- GitHub-verified merge
  `11546539b5fafc46edc533ef4d4501c7d772d677` passed exact-main
  [CI and Sonar](https://github.com/stephenlclarke/container-compose/actions/runs/30194485477),
  [Quality](https://github.com/stephenlclarke/container-compose/actions/runs/30194485472),
  [CodeQL](https://github.com/stephenlclarke/container-compose/actions/runs/30194485476),
  and
  [DocC](https://github.com/stephenlclarke/container-compose/actions/runs/30194485469).
- SonarCloud analysis `2e9b8d8f-a9c5-4643-8b6d-b6cee44a0b68`
  resolved to that exact merge: the quality gate passed with zero unresolved
  issues, bugs, vulnerabilities, code smells, or security hotspots; overall
  coverage was 82.2% and new-code coverage was 82.1% against an 80% gate.
- The upstream/automation refresh found no requested author changes on the
  four open Stephen-authored Apple proposals. The only new automation change,
  [homebrew-tap#3](https://github.com/stephenlclarke/homebrew-tap/pull/3),
  passed its formula check and merged as signed commit
  `9822d8817d3bb5294936b5096e517015837c1cdd`.
- The connector-response audit covered all 229 authored pull requests. It
  added explicit accepted/open dispositions to 79 historical actionable
  threads and a complete follow-up query found zero connector threads without
  a Stephen response.
- Exact-main
  [Prebuilt Binaries run 30195041036](https://github.com/stephenlclarke/container-compose/actions/runs/30195041036)
  passed on the dedicated Apple-silicon runner and published the seven-asset
  [Current build](https://github.com/stephenlclarke/container-compose/releases/tag/current)
  prerelease for `11546539b5fafc46edc533ef4d4501c7d772d677`.
- The Compose archive digest was
  `b2f46ab9be7691bfc4e0fea7e6c15c84ee1168a44e8499e92a8b0e398ba38dba`;
  the matched runtime digest was
  `52cdc0a1c919c4fe73e58838e1b8e2e893de43ba19408debaf8f192dacac20a5`.
  Both release sidecars passed and both GitHub artifact attestations resolved
  to the exact main commit, `prebuilt-binaries.yml@refs/heads/main`, and the
  self-hosted runner invocation.
- Signed atomic Homebrew tap commit
  `4313c131bce678a8eabd09ed7907f6c1b0f25012` published the matched
  `current.880.11546539b5fa` formula pair. The Compose and runtime formulae
  referenced the exact archive URLs and digests above.
- This MBP removed only the stable formula pair, upgraded and linked that
  Current pair, refreshed the plugin registration, and started the Current
  service. Installed provenance reported Compose commit
  `11546539b5fafc46edc533ef4d4501c7d772d677`, Container commit
  `221fafc24ebd19502f4553e0b5d38c14be3f2b22`, and containerization commit
  `164088e02e16ed80e536d0c59822b09931d213df`; `container system status`
  reported `running`.
- The first installed fixture run exposed a test-only timing race: the
  workload's fixed two-second delay could expire before a cold packaged attach
  client subscribed. Replacing that delay with an stdin handshake through the
  attached client made the assertion causal. The installed Current pair and
  Docker Compose V2 then passed signal exit 42, both exact tail assertions,
  failed-client log continuity, and all 13 focused Swift contracts.
- The published 1,600-by-720 GIF is 371.8 seconds and 9,295 frames. Its source
  has 16 typed commands, 16 Enter actions, and 14 live screen waits with no
  replay or marker directive. Frames sampled across startup and workload
  execution show characters being typed and the resulting live output,
  including the real kernel download and Compose service progress.

## PR Template

### Type of Change

- [x] Dependency refresh
- [x] Upstream bug-fix consumption
- [x] Integration coverage
- [x] Documentation update
- [ ] New Compose feature
- [ ] Breaking change

### Motivation and Context

Foreground attach signals failed in the supported stack because the Container client sent an integer where the API server requires a Linux-resolvable string. Adjacent upstream reports showed that log-tail boundaries and dead attach clients also need durable regression evidence. Keeping the implementation in the runtime and the Docker policy oracle in Compose preserves the intended ownership boundary.

### Testing

- [x] Container focused tests
- [x] Container instrumented unit coverage
- [x] Docker Compose V2 reference fixture
- [x] Compose focused tests
- [x] Exact matched Apple runtime fixture
- [x] Complete Compose coverage and quality gates
- [x] Hosted CI and Sonar
- [x] Current package, Homebrew, and attestation verification

### Compatibility and Risk

The source change corrects an internal XPC wire type without changing public API. Canonical names preserve host-to-Linux signal meaning. The Compose repository changes runtime provenance and validation only. The temporary signal port remains independently removable when Apple merges `apple/container#1997`.

The runtime wrapper delays only the private `vminit` configuration write. Its
runtime root, image name, and invoked validation command remain unchanged.

### Reviewer Notes

Review the Container production change separately from the Compose pin. Its stable patch ID matches the existing Apple pull request. The additional runtime test commit changes no production behavior. The Compose fixture deliberately signals the leaf attach client below command wrappers because that process owns signal proxying.

The connector review identified and corrected two validation-harness races:

- the Apple service waiter is reaped in the parent shell and returns its exit
  code through explicit state rather than command substitution;
- the disconnected-client case terminates and reaps the complete client
  process tree, then proves `STREAM:AFTER` does not exist before waiting for
  the workload to write it.

Installed-package verification identified one further fixture race. Readiness
now depends on a line traversing the tested attach client's stdin, so a cold
plugin cannot miss output because of startup duration. This changes only the
fixture's synchronization mechanism; the asserted runtime records and exit
codes are unchanged.

## Commit and Release Tracking

- Container fork merge: `221fafc24ebd19502f4553e0b5d38c14be3f2b22`
- Compose pin commit: `e9a9c13f5f6664583f9e43fceede74ba579b9f4c`
- Matched-runtime harness commit:
  `ae05538dc40e3e6e2698a1be06b1d01063482faf`
- Compose integration/parity commit:
  `a0576253e25ab472eeb8c929ead304479a845c4a`
- Documentation/quality commit:
  `cf2a83a5f7d2ef6ebe5aa966b6eddf9c5ece5800`
- Connector review correction:
  `10423ea7d34d43596cfb99730aa4677112ae0b3b`
- Connector review documentation:
  `b6547398e853035ced8d3023f0792996fa630f39`
- Compose merge:
  `11546539b5fafc46edc533ef4d4501c7d772d677`
- Implementation Current release:
  `current` at `11546539b5fafc46edc533ef4d4501c7d772d677`
  ([run 30195041036](https://github.com/stephenlclarke/container-compose/actions/runs/30195041036))
- Closeout evidence and causal fixture synchronization: this pull request
