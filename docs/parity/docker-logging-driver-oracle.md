# Docker Logging-Driver Oracle

This oracle records the Docker Engine behavior that the logging-driver implementation must reproduce. It is a focused Engine API reference, not a test of the `container-compose` implementation.

The committed fixture is pinned to Docker Engine 29.2.1, API 1.53, Docker Compose 5.3.1, the active `colima` context on an arm64 Mac17,9 running macOS 26.5.2, and a preloaded `alpine:3.20` image. Its runtime fingerprint includes the Docker client, Engine commit, Engine Go and kernel versions, Colima version, host identity, registered logging drivers, and image repository digest so that an environment change is visible in review.

## Covered Semantics

The capture covers:

- omitted `HostConfig.LogConfig` resolving to the daemon's `json-file` default;
- explicit `json-file`, `local`, `none`, and `syslog` driver identities and arbitrary option preservation, including Engine acceptance of options on `none`;
- create-time option-name rejection versus start-time option-value rejection, including container residue and inspect state;
- Syslog address, facility, format, metadata-regex, tag-template, and TLS-material validation phases, including accepted empty UDP ports and case-insensitive schemes, the pinned IPv6 default-port failure, Go integer facility spellings, unused invalid regexes, control-flow and whitespace-trimming template actions, and transport-dependent TLS file loading;
- empty driver resolution and the exact create/start validation phases for `mode`, `compress`, `max-size`, `max-file`, and `max-buffer-size`, including the pinned Moby distinction between decimal `max-size` (`4k` is 4,000 bytes) and binary `max-buffer-size` (`4k` is 4,096 bytes);
- representative Go `strconv.ParseBool` spellings, Docker/go-units size spellings, and whitespace behavior;
- `HostConfig.LogConfig`, `LogPath`, stopped-container reads, restart retention, and the effect of a created-container follow read;
- non-TTY stdout/stderr selection and Docker's eight-byte multiplex framing;
- TTY raw, merged output and stream-filter behavior;
- live TTY attach over the Docker HTTP upgrade protocol, observable terminal resize, configured detach keys that leave the workload running, independent reattachment, later output, terminal exit, and exact cleanup;
- raw `json-file` record keys, streams, labels, and RFC 3339 nanosecond timestamp shape;
- native-reader behavior for `local`; and
- the default dual-logging cache, `cache-disabled` grammar, and retention without create/start rejection of the other `cache-*` options for both reader and non-reader drivers; pinned Moby 29.2.1 retains but does not remap `cache-max-size`, `cache-max-file`, or `cache-compress`, so the local cache keeps its fixed 20 MiB/five-file/compressed defaults;
- sustained `json-file` and `local` rotation at a 4,000-byte (`4k`) limit, three-file retention, valid gzip compression, one-record threshold overflow, retained ranges, and `json-file` suffix-to-record ordering;
- non-blocking delivery under a controlled two-second Unix-stream sink stall, including guest write completion before sink release, observable dropped-new gaps, order, uniqueness, and final-record loss;
- Docker `syslog` delivery through VM-local UDP, TCP, authenticated TLS, and Unix-stream receivers, including RFC 5424 microsecond fields, `local1` stdout/stderr priorities, expanded name/ID tags, ASCII/UTF-8/binary-with-NUL payload bytes, UDP datagram boundaries, TCP/Unix LF framing, TLS octet counting, peer shutdown, and exact receiver cleanup;
- Docker `fluentd` delivery through VM-local TCP and Unix-stream receivers, including the four-element Fluent Forward MessagePack envelope, string and invalid-UTF-8 string encodings, container/stream/label/environment metadata, integer-second versus EventTime timestamps, request-ack chunk tokens and ACK completion, EOF on logger shutdown, and an async Unix reconnect that delivers records buffered before the receiver exists; and
- Docker Compose foreground output for `json-file`, `none`, and cache-disabled `syslog`, proving that early stdout/stderr remains visible exactly once even when later historical reads are unsupported;
- Docker Compose static history for `none`, which exits successfully with an empty stream and continues readable services, while followed/direct reads retain the unsupported-reader failure; and
- the reusable signal/log CLI fixture for readable/`none` non-TTY foreground output, restart retention, three-replica aggregation, tails, signal forwarding, disconnected-client persistence, and exact cleanup.

The `none` option case deliberately calls the Engine API directly. Docker's CLI performs additional client-side validation and rejects that request before it reaches the daemon; the runtime compatibility contract is the Engine behavior captured here.

## Run The Oracle

Prerequisites are `docker`, `colima`, the selected Docker context `colima`, Docker Engine 29.2.1 exposing API 1.53, and the pinned image already present locally. The harness never pulls or removes images.

Compare a fresh capture with the committed fixture:

```sh
python3 Tools/parity/capture-docker-logging-driver-oracle.py --strict
```

Without `--strict`, a missing or mismatched pinned environment is reported as a skip. Any probe failure, semantic difference, or cleanup failure still exits nonzero.

Write a candidate capture elsewhere for review:

```sh
python3 Tools/parity/capture-docker-logging-driver-oracle.py --strict --output /tmp/docker-logging-oracle.json
```

After intentionally changing the pinned reference, update the versioned fixture and review the complete diff:

```sh
python3 Tools/parity/capture-docker-logging-driver-oracle.py --strict --update
```

The committed evidence is [`docker-engine-29.2.1-logging.json`](../../Tests/ComposeCoreTests/Fixtures/logging/docker-engine-29.2.1-logging.json), and focused fixture assertions live in [`DockerLoggingDriverOracleFixtureTests.swift`](../../Tests/ComposeCoreTests/DockerLoggingDriverOracleFixtureTests.swift).

The live terminal session is deliberately a separate short-running capture so that it can also be executed unchanged against the Container public Docker socket. Capture and compare the pinned reference with:

```sh
make docker-terminal-session-oracle
```

With the matched Container system running, compare its public gateway with the same semantic fixture:

```sh
make docker-terminal-session-candidate-oracle
```

That target defaults to `/tmp/container-engine-$(id -u)/docker.sock`; override `DOCKER_TERMINAL_CANDIDATE_SOCKET` for an isolated installation. The committed [`docker-engine-29.2.1-terminal-session.json`](../../Tests/ComposeCoreTests/Fixtures/logging/docker-engine-29.2.1-terminal-session.json) fixture and [`DockerTerminalSessionOracleFixtureTests.swift`](../../Tests/ComposeCoreTests/DockerTerminalSessionOracleFixtureTests.swift) pin the exact 101 upgrade headers, raw TTY bytes, dimensions, detach sequence, reattachment, exit state, and cleanup contract.

Signed local Engine API `c7973ac641fb6f6e07df1358114f36222bd9ca59` and Container `a10ad44d8675b27a665d72fbe054f12f403f8412` pass this semantic and <10× regression gate. The candidate improved from 4.359129 seconds before the peer-identity cache to 1.238173 seconds on the first post-start capture and 0.920554 seconds warm; the committed Docker reference is 0.184992 seconds. The remaining 6.69× cold and 4.98× warm ratios are retained as a comparable-performance gap rather than being hidden by the regression threshold.

## Compose Signal and Log Reliability Gate

The same-host Docker Compose 5.3.1/candidate CLI gate runs the committed [`signal-log-reliability`](../../Tools/parity/fixtures/signal-log-reliability/compose.yaml) project and Bash harness:

```sh
CONTAINER_COMPOSE_LIVE=1 \
CONTAINER_COMPOSE_CONTAINER=/path/to/exact/signed/container \
CONTAINER_STACK_REPO=/path/to/container \
CONTAINERIZATION_STACK_REPO=/path/to/containerization \
CONTAINER_ENGINE_API_STACK_REPO=/path/to/container-engine-api \
make docker-compose-signal-log-reliability-parity
```

The 5 August 2026 Verified checkpoint used Compose `c7a50e28438ca0c5bd5a668d3b8e87db25c4a176`, Container `bfa8b361901e33bc427d5bb551d19b2a224ca3f2`, Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`, Engine API `c7973ac641fb6f6e07df1358114f36222bd9ca59`, Docker Compose 5.3.1, and Docker Engine 29.2.1. Both lanes passed readable and `none` foreground output, successful empty static `none` history, restart retention, three-replica foreground/history aggregation, long and filtered tails, signal forwarding, disconnected-client logging, and exact cleanup. The embedded focused Swift gate passed 19 tests in two suites; the sourceable Bash identifier assertion passed three Python regressions, including non-hex hyphenated candidate hostnames.

The candidate graph must use identity-preserving local package roots for Container, Containerization, and Engine API because these coordinated revisions are intentionally unpublished. The target records that graph before runtime validation and restores `Package.resolved` afterwards.

## Determinism And Cleanup

Each Engine probe uses a unique `cc-log-oracle-*` container name and force-removes every tracked container in a `finally` path. The pressure probe uses exact, unique socket, PID, and result paths inside the Colima VM; it validates and removes all three without broad process matching. Remote-wire probes use bounded Python receivers inside the same Colima VM as the Docker daemon. Each receiver has unique ready, result, PID, socket, certificate, and key paths as applicable; cleanup addresses only those exact paths, validates the exact PID command line before signalling, and proves that the process and paths are gone. TLS uses a one-day, per-run CA certificate generated inside Colima and supplied through Docker's `syslog-tls-ca-cert` option. Each foreground probe uses a unique Compose project and host temporary directory, runs `down --volumes --remove-orphans`, and verifies that its container and default network no longer exist. Cleanup is verified before the script exits. No probe creates a persistent Docker network or volume.

The terminal-session capture similarly generates one unique `cc-terminal-oracle-*` name, addresses only its returned container identifier, force-removes it in a `finally` path, and proves the exact identifier returns HTTP 404 before exiting. Reads, process-exit polling, and the hijacked session are bounded; the harness creates no network or volume.

Volatile container IDs, names, ports, paths, certificates, daemon PIDs, timestamps, Fluentd chunk tokens, and byte counts derived from volatile field lengths are replaced with typed placeholders or canonical normalized counts. Valid JSON timestamps become `<rfc3339-nano-utc>`; Syslog timestamps become `<rfc3339-micro-utc>` while retaining their six-digit resolution; Fluentd timestamps retain their exact MessagePack integer or `fixext8` EventTime representation. Raw JSON records are sorted by stream. Fluent Forward maps are semantically unordered, so map-entry order is normalized while every scalar wire type and top-level array position remains frozen. Docker may vary socket read chunk boundaries, so receivers concatenate the byte stream and decode protocol framing rather than treating a `recv` boundary as evidence. The workload inserts bounded pauses to make stdout/stderr source order deterministic, and the fixture retains that wire order.

Every top-level case records a raw `time.monotonic` duration in the machine-readable fixture. Strict comparison reports each fresh duration, ignores ordinary timing variance when comparing semantic JSON, and fails when a fixture times out or takes at least ten times its committed baseline. Candidate captures written with `--output` retain the raw values.

The oracle does not provision external logging services or installed logging plugins. Cloud-driver delivery, a blocking slow-sink backpressure case, dual-cache rotation under sustained load, and plugin lifecycle behavior still require separate focused oracles.

Docker accepts a `tls://` Fluentd address, but its Fluentd option grammar exposes no CA path or skip-verification option. The versioned `tlsLocalTrustFailure` probe freezes the boundary: against its bounded self-signed receiver, Engine 29.2.1 accepts container creation with HTTP 201 and rejects start with HTTP 500: `tls: failed to verify certificate: x509: certificate signed by unknown authority`; the receiver independently observes the resulting TLS bad-certificate alert. Capturing decrypted Fluentd TLS wire bytes would therefore require a deliberate Colima trust-store mutation or a publicly trusted endpoint. This harness does neither, so Fluentd TLS remains an explicit evidence gap; Syslog TLS is fully captured because that driver exposes `syslog-tls-ca-cert`.

The exact non-blocking delivered count and marker set are also not frozen: three back-to-back calibrations preserved order and uniqueness and always dropped records, but the final delivered marker varied between 315, 565, and 576 because daemon scheduling and kernel buffering are observable inputs. The fixture therefore freezes only deterministic pressure invariants; exact ring capacity, drop-new admission, and close-drain mechanics remain covered by the pinned Moby source-level contract and implementation tests rather than an unstable black-box count.
