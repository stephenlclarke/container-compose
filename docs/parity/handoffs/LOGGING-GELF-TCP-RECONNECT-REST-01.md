# LOGGING-GELF-TCP-RECONNECT-REST-01 Handoff

## State

`Verified` as a narrow Docker CLI/public-socket TCP GELF peer-loss and reconnect
contract. It is not a full remote-driver, failing-sink, external-client, or
comparable-or-better release-performance certification.

## User-visible contract

The same unmodified Docker CLI creates a cache-disabled TCP `gelf` container
against Docker Engine 29.2.1 and a fresh local Container public socket. A
bounded receiver accepts the first NUL-framed GELF record, closes that TCP peer,
and requires a second valid stream with ordered recovery bytes and the terminal
`reconnect-complete` record. The certificate also checks Docker-shaped reconnect
option projection, metadata/tag fields, inspect state, unsupported remote
history, native authority, and exact cleanup.

## Exact proof

The marker-protected root
`/private/tmp/container-gelf-tcp-reconnect-candidate-v2.nmMgi1` contains
`FINGERPRINT-PREFLIGHT.json`, `ARCHIVE-VERIFICATION.json`, and
`FINGERPRINT-COMPLETE.json`; the code-signed archive; individual binary and
guest-image hashes; the harness and wrapper hashes; and two candidate result and
runtime-log pairs. It binds Compose
`ecddcb06a33728e99a1471fbbf2701d892dbbc60`, signed Container
`2a60d0ad0341ef6947d30289488e3a7c8eac56ed`, local Containerization
`38d9c695e7a6915e5ce45d12c893dc323a661af7`, and Engine API
`4949e743675f00ec102f7acacdb4e990409e383f`.

The Docker CLI 29.7.1 / Engine 29.2.1 reference is retained at
`/private/tmp/container-gelf-tcp-reconnect-reference-v2.yjav2A/docker-reference-result.json`.
It passed in `5.524841000s`. The two independent candidate public-socket runs
passed in `6.508964500s` and `6.340717583s` (1.18× and 1.15× Docker). They meet
the fixture's 10× functional guard. One reconnect lane near the reference does
not establish programme-wide comparable-or-better release performance.

The source correction has a live regression:
`GELFTransportLoopbackTests.productionDockerHostAliasRoutesTCPAndUDPToNativeLoopback`
passes against the exact local Containerization `38d9c69` and Engine API
`4949e743` graph. Its marker-protected evidence is
`/private/tmp/container-gelf-native-alias-unit-matched.D850uv/swift-test.log`.

## Correction retained as evidence

The initial public candidate did not exercise reconnect because its native macOS
GELF provider tried to resolve Docker's VM-only `host.docker.internal` alias and
failed before delivery. Signed Container `2a60d0ad0341ef6947d30289488e3a7c8eac56ed`
preserves the public Docker configuration but maps that alias, case-insensitively,
to `127.0.0.1` only while the native TCP or UDP transport opens its socket. The
focused TCP/UDP loopback regression and both fresh public reconnect runs pass.

## Remaining boundary

The complete TCP retry/failure matrix, slow/failing sinks, backpressure,
dual-cache pressure, migration/security/provider-failure matrices, other remote
drivers, Testcontainers/devcontainer lanes, release publication, and complete
release-performance proof remain queued. [Container issue
74](https://github.com/stephenlclarke/container/issues/74) still owns the
unrelated public create name-as-ID discrepancy. The Apple-shaped source handoff
is local only; no Apple issue, pull request, branch publication, or push is
authorised.

## Safe resumption

Keep the marker-protected candidate root, Docker reference root, signed Container
checkpoint, this handoff, and Slack START thread `1785988164.118569`. Do not
repeat broad gates for this completed narrow contract. Select one independent
queued contract, poll Slack before its START, and preserve the existing evidence.
