# LOGGING-SYSLOG-TCP-REST-01 Handoff

## State

`Verified` as a narrow Docker CLI/public-socket Syslog TCP certificate for the stopped cache-disabled `docker logs` path. It proves functional semantics only and does not claim every Syslog transport, provider/external client, failure/migration/security path, or comparable-or-better release performance.

## User-visible contract

The same unmodified Docker CLI creates and starts a cache-disabled `syslog` container with `syslog-address=tcp://host.docker.internal:<port>` and `syslog-format=rfc5424micro`. A local TCP receiver observes ordered stdout, stderr, and binary records with Docker-compatible framing, `local1` facility/severity, and Docker tag expansion. After exit, `docker logs` opens and closes one additional empty TCP connection before returning `Error response from daemon: configured logging driver does not support reading`. Inspect, native authority visibility, and cleanup use the same public socket contract.

## Exact proof

The marker-protected Docker reference root `/private/tmp/container-syslog-tcp-reference-v8.YBX82T` records Docker CLI `29.7.1`, Engine `29.2.1`, API `1.53`, the exact harness, and a passing `0.967602000s` result. Its receiver capture has two total connections, one post-exit connection, and `postExitStreamsHex=[""]`.

The marker-protected candidate root `/private/tmp/container-syslog-tcp-candidate-v4.OZHeoC` contains `FINGERPRINT-CANDIDATE-RUN-1-PREFLIGHT.json`, `FINGERPRINT-CANDIDATE-RUN-2-PREFLIGHT.json`, and `FINGERPRINT-COMPLETE.json`. It binds signed Container `b82e34874b944d2b9ecc65d4068aee5d7b46905e`, local Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`, Engine API `4949e743675f00ec102f7acacdb4e990409e383f`, Compose base `603bc8d5536fc176e745d034fbc42e386bafbbba`, harness SHA-256 `69bd8acd61e5986304e88dc9f15b1bf883c485ef4aad4a5336bf312af92dbf5d`, the signed archive/binaries, guest init/bootstrap archives, runtime kernel, wrapper, results, and cleanup.

Candidate public-socket runs passed in `2.003332125s` and `1.660303875s` (2.07× and 1.72× Docker). These are below the focused 10× functional guard, not comparable-or-better programme performance evidence.

## Source proof and correction

`SyslogProviderTests` passes 8/8 on the exact matched local overlay. Instrumented evidence records 10/10 executable lines covered in `SyslogLogDriverProvider.recreateStoppedLogger`.

Pinned Moby behavior creates a stopped Syslog logger before it recognizes the lack of a reader. The prior candidate skipped that one-shot provider initialization and returned the public unsupported-history error directly, so it had no second TCP connection. The correction constructs and closes a transient native Syslog session only for stopped unavailable reads, using the same typed configuration as writer registration; successful creation still maps to the Docker unsupported-history error and connect failures remain visible.

## Remaining boundary

Syslog TLS and Unix sockets, retry and failing-sink behavior, backpressure, option completeness, every remote driver, external clients, Testcontainers/devcontainer adoption, publication, and counterbalanced comparable-or-better release performance remain queued. The UDP certificate remains separate in [LOGGING-SYSLOG-UDP-REST-01](LOGGING-SYSLOG-UDP-REST-01.md).

## Safe resumption

Keep both marker-protected evidence roots and the signed source checkpoint. No Apple issue, pull request, branch publication, or push has been created because Apple `origin/main` lacks this fork-only Syslog provider path. The Stephen-owned [Container issue #79](https://github.com/stephenlclarke/container/issues/79) is closed after the final evidence comment. Do not rerun broad gates for this completed narrow contract; select a distinct queued contract after polling Slack. The completed slice START thread is `1786006125.498149`.
