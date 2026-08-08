# LOGGING-GELF-TCP-RETRY-DELAY-01 Handoff

## State

`Active` — Candidate 7's bounded generic startup failure exposed a causal
diagnostic gap. Signed local Container `54c5b332a204c01da34029c7fadabb560520c887`
now preserves a redacted Engine-Linux bootstrap phase with focused proof. One
new exact-fingerprint candidate may run to expose the failing layer or advance
to the delayed-retry behavior match. It is not `Verified` until two independent
public-socket candidates match the Docker oracle.

## User-visible contract

The unmodified Docker CLI creates a cache-disabled TCP `gelf` container with a
positive `gelf-tcp-max-reconnect` budget and a non-zero
`gelf-tcp-reconnect-delay`. A bounded receiver forces successive peer resets,
records retry timing and delivery/disposition, then verifies terminal recovery,
lifecycle, inspect projection, native authority visibility, and cleanup through
Docker Engine 29.2.1 and Container's candidate public socket.

## Explicit non-goals

This contract does not certify slow-sink throughput, a complete remote-driver
matrix, UDP behavior, dual-cache pressure, plugins, migration, security,
external clients, devcontainer adoption, or release publication. Performance
is designed for and raw timing is retained, but optimization and
comparable-or-better measurement are a post-functional programme phase unless
a run hangs or exceeds its liveness bound.

## Pinned Docker oracle

Same-MBP Docker CLI `29.7.1`, Docker Engine `29.2.1` (API `1.53`), Colima,
and `alpine:3.20`. The retained reference is
`/private/tmp/container-rest-gelf.default-host.wG4HQt`: the strict
`tcp-retry-delay` fixture passed in `22.447226208` seconds with result
SHA-256 `ecb6fc023506a605c360f4032a59a26138daa0898d3dfd2db3e1c7ac1f363abe`.
Its receiver recorded two one-frame forced resets, delay intervals
`10.019107917` and `9.010752833` seconds, terminal recovery, peer close,
and no timeout.

## Affected repositories and inputs

- `container-compose` `main` at
  `c8ebcb79bfa89229619678cb6f42334f0298d3c9`: the
  `check-docker-rest-gelf-contract.sh` harness at SHA-256
  `a0ed0178a62be517b42d4a21070ea73a57689513b7a623c3fcdfcdd6efc94fca`.
- Container Candidate 6 source was signed
  `09627527f7f2957548447739fff64021888145c8`; Candidate 7 source was signed
  `b39f56635d0ab81a06d690b39eed9f5f106e2e26`. The current diagnostic source is
  signed Container `54c5b332a204c01da34029c7fadabb560520c887` on local
  `upstream/logging-gelf-tcp-retry-diagnostic-01`.
- The exact current focused-test graph is local Containerization
  `38d9c695e7a6915e5ce45d12c893dc323a661af7` and Engine API
  `f5d0d120bb139675e96a4ef9f7b0ac800827c295`. This matching local graph is
  test-only evidence; no published dependency pin moved.
- Both candidates use committed Container `Package.resolved` SHA-256
  `c60ff0b8ae4dfac5ef80733453c273141a9070028e34d75d6afafc65a3147e53`,
  guest-init OCI SHA-256
  `5d4201135affb9bb0ce34ebcb184551689a214d3118b75564a8fa498667d77f6`,
  bootstrap OCI SHA-256
  `c714ab7421c71cebdfd0236c5a1af4b1e9af3da1855946cf3350a384491815f0`, and
  runtime-wrapper SHA-256
  `7a396d8626a0e37c1b7f71e732674baebd1b3752bedc3378a7e4510e3323987f`.

## Focused proof and blocker evidence

The sealed Linux/arm64 GELF lane and its prior `make test-gelf-service`
format/vet/race/manifest/90.5%-coverage proof remain preserved. Candidate 6's
direct host-to-guest Journald VSOCK dial reset with POSIX 54. Candidate 7 used
reverse host VSOCK for both protected services, then exited 1 within the
180-second liveness bound before the host receiver accepted a TCP peer. It
reported Docker's generic `container logging operation failed`; it did not hang.

The new diagnostic checkpoint establishes that
`remoteLogDriverPlane.prepareBootstrap` runs before `RuntimeClient` and that
the causal loss occurred in `GELFTCPServiceWireConnectionV1.call`, which
collapsed protected bootstrap errors into a generic transport error. Container
`54c5b332` introduces a redacted startup/readiness/identity phase, maps it to
the existing endpoint GELF provider/Docker diagnostic, and keeps writes and
retry ownership generic. `GELFTCPServiceWireTests` (10),
`EngineLinuxSandboxGELFTCPServiceTests` (17), and
`ContainerLoggingStartErrorTests` (5) pass together. The changed production
files have 93.69% and 93.71% focused line coverage; selected aggregate line
coverage is 96.45%. Strict Swift formatting, parse validation, and
`git diff --check` pass. No fresh public candidate has run from this checkpoint.

## Completion criteria

- The Docker reference remains a stable delayed-retry observable.
- Two independent exact-fingerprint public-socket candidates match its
  configuration, record ordering/disposition, retry behavior, lifecycle,
  inspect state, authority visibility, and cleanup.
- Changed production code has focused evidence approaching the 90% coverage
  target, and the repository-owned Bash fixture passes syntax, ShellCheck, the
  Docker oracle, and the candidate runs.
- Performance architecture and raw duration evidence are retained for the
  later optimization phase. Comparable-or-better timing is not a prerequisite
  for functional verification; any hang or liveness-bound breach remains a
  functional blocker.

## Blocker criteria and next safe action

The required typed diagnostic is now implemented and has focused proof. The
next action is exactly one fresh marker-protected candidate after a preflight
binds source `54c5b332`, dependencies, binary/archive, guest/init images,
harness/wrapper, and disposable root in one fingerprint. Record a new causal
stage or a behavior match; do not infer either before that run. Treat an
unexpected hang or timeout as an immediate blocker; Candidate 7 was not one.
[Container issue #89](https://github.com/stephenlclarke/container/issues/89)
tracks this diagnostic handoff and remains open until the focused correction is
verified.

## Safe handoff

Preserve the Docker reference above; Candidate 6 and Candidate 7 roots; their
`FINGERPRINT-CANDIDATE-*-PREFLIGHT.md` and
`ARCHIVE-VERIFICATION-CANDIDATE-*.md` records; Candidate 7 runtime root
`/private/tmp/ctr-gelf-reverse-vsock-run.rEhN6S`; fixture root
`/private/tmp/container-rest-gelf.reverse-vsock.fixture.l5GRB6`; signed source
`54c5b332`; and its two exact focused-test dependency worktrees. Do not rebuild,
restart, or remove retained roots merely to investigate the failure. The next
runtime root must be new, marker-protected, and namespace-aware; it must not
stop or reuse the user-owned devcontainer engine.

## Documentation disposition

This handoff and the slice ledger distinguish functional verification from the
later performance programme. They record the exact failed candidate fingerprints
and the now-implemented diagnostic checkpoint; they do not claim complete GELF
or logging-driver closure.
