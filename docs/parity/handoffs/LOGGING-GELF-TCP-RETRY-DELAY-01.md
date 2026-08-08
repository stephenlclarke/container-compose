# LOGGING-GELF-TCP-RETRY-DELAY-01 Handoff

## State

`Blocked` — the pinned Docker reference remains valid, but two exact-fingerprint
candidate corrections reached distinct functional failures. Candidate 7 is
bounded and exits with status 1 rather than hanging; it is not a performance
blocker. Do not retry this candidate lane without a new causal diagnostic.

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
  `09627527f7f2957548447739fff64021888145c8`; Candidate 7 source is signed
  `b39f56635d0ab81a06d690b39eed9f5f106e2e26` on
  `upstream/logging-fluentd-tls-alert-control-01`.
- Local Containerization is signed
  `ecb2ac5099a8521f02c248870fa6dd7aa7518465` on
  `upstream/vsock-connection-lifetime-01`; local Engine API is
  `f5d0d120bb139675e96a4ef9f7ac800827c295`.
- Both candidates use committed Container `Package.resolved` SHA-256
  `c60ff0b8ae4dfac5ef80733453c273141a9070028e34d75d6afafc65a3147e53`,
  guest-init OCI SHA-256
  `5d4201135affb9bb0ce34ebcb184551689a214d3118b75564a8fa498667d77f6`,
  bootstrap OCI SHA-256
  `c714ab7421c71cebdfd0236c5a1af4b1e9af3da1855946cf3350a384491815f0`,
  and runtime-wrapper SHA-256
  `7a396d8626a0e37c1b7f71e732674baebd1b3752bedc3378a7e4510e3323987f`.

## Focused proof and blocker evidence

The sealed Linux/arm64 GELF lane previously passed `make test-gelf-service`,
including format, vet, race tests, deterministic manifest verification, and its
90.5% statement coverage gate. The Candidate 7 correction adds reverse-VSOCK
support to Journald so both protected service workloads use the sealed
guest-to-host transport. `make test-journald-service` passed, as did the
focused `EngineLinuxSandboxJournaldServiceTests` (7 tests), strict Swift
formatting, and `git diff --check`.

Candidate 6
(`/private/tmp/container-gelf-vsock-lifetime-candidate.J23aUR`) packaged the
exact signed source and local dependency graph, but its host-to-guest Journald
VSOCK dial on port 19530 reset with POSIX 54. Candidate 7
(`/private/tmp/container-gelf-reverse-vsock-candidate.fcP69s`) packages the
same Containerization and Engine API heads with signed Container
`b39f566…`; its package archive SHA-256 is
`4efa3490468e1aafeeb0c02cac98c69fee9af79da36e5e39bc5ad4eba2acab3c`.
Its archive verification records strict code-signing success and the exact
CLI/API/runtime/guest assets.

Candidate 7 selected reverse host VSOCK for both Journald (port 19530) and GELF
(port 19532), and the guest started both managed services. It then exited
within the 180-second bound with status 1:

```text
Error response from daemon: container logging operation failed
failed to start containers: 79a0905b71df4412b73f71ed7598304348b44eab74a04135b0c1242bc691ad8a
```

The host receiver accepted no TCP peer. The generic Docker error is emitted
after `RuntimeClient.bootstrap` discards the underlying cause, while neither
the runtime nor the protected service log captured a typed wire/open failure.
This evidence does not establish an endpoint-alias, VSOCK, or GELF protocol
root cause. It only proves that the Candidate 6 direct-transport correction and
Candidate 7 symmetric reverse-transport correction did not complete the
functional contract.

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

Two evidence-based corrections have now failed, so this contract must not
consume another runtime retry. The next work on this exact contract must first
add a small, typed diagnostic at the bootstrap-to-Docker-error boundary and at
the GELF service open/response boundary, with focused tests proving that the
original cause survives the mapping. Only after that evidence identifies the
failing layer may a new marker-protected candidate be assembled. Treat an
unexpected hang or timeout as an immediate blocker; Candidate 7 was not one.
[Container issue #89](https://github.com/stephenlclarke/container/issues/89)
tracks this diagnostic handoff and remains open until the focused correction is
verified.

## Safe handoff

Preserve the Docker reference above; Candidate 6 and Candidate 7 roots; their
`FINGERPRINT-CANDIDATE-*-PREFLIGHT.md` and
`ARCHIVE-VERIFICATION-CANDIDATE-*.md` records; Candidate 7 runtime root
`/private/tmp/ctr-gelf-reverse-vsock-run.rEhN6S`; and fixture root
`/private/tmp/container-rest-gelf.reverse-vsock.fixture.l5GRB6`. Keep both
signed source checkpoints and the marker-protected guest/bootstrap inputs
unchanged. Do not rebuild, restart, or remove these roots merely to investigate
the failure. Select an independent queued contract while this one is blocked.

## Documentation disposition

This handoff and the slice ledger now distinguish functional verification from
the later performance programme. They record the exact failed candidate
fingerprints, the evidence gap, and the required diagnostic handoff; they do
not claim complete GELF or logging-driver closure.
