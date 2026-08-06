# LOGGING-GELF-TCP-REST-01 Handoff

## State

`Verified` as a narrow Docker CLI/public-socket GELF TCP contract. It verifies
functional semantics only; it does not itself claim the separately verified
bounded reconnect path, all remote-driver/external-client behavior, or
comparable-or-better release-performance parity.

## User-visible contract

The same unmodified Docker CLI creates a cache-disabled `gelf` container against
Docker Engine 29.2.1 and against a fresh local Container public socket. The
certificate proves uncompressed NUL-delimited TCP GELF JSON records; ordered
stdout, stderr, and binary payloads; priorities; selected environment/label
metadata; tag expansion; unqualified image display; peer EOF after exit; exited
inspect state with blank public `LogPath`; unsupported remote history; native
authority visibility; and cleanup.

## Exact proof

The marker-protected root
`/private/tmp/container-gelf-tcp-rest-v3.Zd0bfm` contains
`FINGERPRINT-PREFLIGHT.json`, the code-signed extracted release archive, binary
hashes, guest-image hashes, and three candidate result files. It records Compose
base `414c04c0cb4d47d59e78c483f481270dc869a6fa` plus the TCP harness SHA-256
`bc14f05007a2da1940042153b6bc20d7871a8b0664b5827b7cb4cf30ef7887eb`,
Container `9999d994ed45e06ed2c3144bb175230427116fbc`, local Containerization
`38d9c695e7a6915e5ce45d12c893dc323a661af7`, transitive Containerization
`77f06d4c44341e04241941072fb69e2b85a6f5c1`, and Engine API
`4949e743675f00ec102f7acacdb4e990409e383f`.

The Docker reference result is retained at
`/private/tmp/container-gelf-tcp-rest-v2.8GcpKZ/docker-reference-result.json`.
It passed in `0.931894667s`. Candidate public-socket runs passed in
`1.603390667s`, `1.700857709s`, and `1.975864916s` (1.72×, 1.83×, and 2.12×).
They are functional passes below the fixture's 10× guard, not a
comparable-or-better performance result.

The Bash fixture passed `bash -n` and ShellCheck. Its default UDP branch was
also rerun against the Docker reference after the shared transport refactor;
that focused regression passed in `0.669117458s` under
`/private/tmp/container-gelf-udp-regression-v1.s4goZJ`.

## Correction retained as evidence

The initial TCP reference fixture closed its listener immediately after the
delivery connection reached EOF. Docker initializes the remote logger again
when `docker logs` opens, so the result was a connection-refused setup error
instead of the expected unsupported-history error. The fixture now records the
primary EOF, keeps the bounded listener available through that call, and only
then completes. The corrected Docker reference and all three candidate runs
pass; this was a harness-lifecycle correction, not a Container semantic
mismatch.

## Remaining boundary

One bounded TCP peer-loss/reconnect path is separately verified in
[LOGGING-GELF-TCP-RECONNECT-REST-01](LOGGING-GELF-TCP-RECONNECT-REST-01.md).
The remaining retry/failing-sink matrix, provider-wide failure/migration/security
and pressure behavior, other remote-driver public-client lanes,
Testcontainers/devcontainer adoption, release publication, and the complete
release performance matrix remain queued. The candidate create route still
returns a generated name instead of Docker's immutable 64-hex ID; [Container
issue 74](https://github.com/stephenlclarke/container/issues/74) tracks that
separately.

## Safe resumption

Keep both marker-protected evidence roots and the signed Container checkpoint.
Do not rerun broad gates for this completed narrow contract. Select a distinct
queued contract, and poll Slack before any new slice START; the completed
slice's START thread is `1785987039.525399`.
