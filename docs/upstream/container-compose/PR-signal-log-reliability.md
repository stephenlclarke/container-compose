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
  - defines the attach-signal, long-tail, multi-record, and client-disconnect workloads.
- `Tools/parity/check-compose-signal-log-reliability.sh`
  - runs the same fixture through Docker Compose V2 and the optional matched Apple runtime.
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
  clients were terminated.
- The isolated runtime wrapper ordering regression passed.
- 13 focused Compose attach/log adapter tests passed.
- 1,218 Swift tests in 41 suites passed.
- Swift line coverage was 92.13% against a 90% gate.
- Go statement coverage was 89.88% against an 85% gate.

Sonar, hosted CI, package, Homebrew, and Current release results are appended
before the slice closes.

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
- [ ] Hosted CI and Sonar
- [ ] Current package, Homebrew, and attestation verification

### Compatibility and Risk

The source change corrects an internal XPC wire type without changing public API. Canonical names preserve host-to-Linux signal meaning. The Compose repository changes runtime provenance and validation only. The temporary signal port remains independently removable when Apple merges `apple/container#1997`.

The runtime wrapper delays only the private `vminit` configuration write. Its
runtime root, image name, and invoked validation command remain unchanged.

### Reviewer Notes

Review the Container production change separately from the Compose pin. Its stable patch ID matches the existing Apple pull request. The additional runtime test commit changes no production behavior. The Compose fixture deliberately signals the leaf attach client below command wrappers because that process owns signal proxying.

## Commit and Release Tracking

- Container fork merge: `221fafc24ebd19502f4553e0b5d38c14be3f2b22`
- Compose pin commit: `e9a9c13f5f6664583f9e43fceede74ba579b9f4c`
- Matched-runtime harness commit:
  `ae05538dc40e3e6e2698a1be06b1d01063482faf`
- Compose integration/parity commit:
  `a0576253e25ab472eeb8c929ead304479a845c4a`
- Documentation/quality commit:
  `cf2a83a5f7d2ef6ebe5aa966b6eddf9c5ece5800`
- Current release: pending
