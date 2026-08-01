# Docker Logging-Driver Oracle

This oracle records the Docker Engine behavior that the logging-driver implementation must reproduce. It is a focused Engine API reference, not a test of the `container-compose` implementation.

The committed fixture is pinned to Docker Engine 29.2.1, API 1.53, Docker Compose 5.3.1, the active `colima` context on an arm64 Mac17,9 running macOS 26.5.2, and a preloaded `alpine:3.20` image. Its runtime fingerprint includes the Docker client, Engine commit, Engine Go and kernel versions, Colima version, host identity, registered logging drivers, and image repository digest so that an environment change is visible in review.

## Covered Semantics

The capture covers:

- omitted `HostConfig.LogConfig` resolving to the daemon's `json-file` default;
- explicit `json-file`, `local`, `none`, and `syslog` driver identities and arbitrary option preservation, including Engine acceptance of options on `none`;
- create-time option-name rejection versus start-time option-value rejection, including container residue and inspect state;
- empty driver resolution and the exact create/start validation phases for `mode`, `compress`, `max-size`, `max-file`, and `max-buffer-size`, including the pinned Moby distinction between decimal `max-size` (`4k` is 4,000 bytes) and binary `max-buffer-size`/`cache-max-size` (`4k` is 4,096 bytes);
- representative Go `strconv.ParseBool` spellings, Docker/go-units size spellings, and whitespace behavior;
- `HostConfig.LogConfig`, `LogPath`, stopped-container reads, restart retention, and the effect of a created-container follow read;
- non-TTY stdout/stderr selection and Docker's eight-byte multiplex framing;
- TTY raw, merged output and stream-filter behavior;
- raw `json-file` record keys, streams, labels, and RFC 3339 nanosecond timestamp shape;
- native-reader behavior for `local`; and
- the default dual-logging cache, `cache-disabled` grammar, and retention without create/start rejection of the other `cache-*` options for both reader and non-reader drivers;
- sustained `json-file` and `local` rotation at a 4,000-byte (`4k`) limit, three-file retention, valid gzip compression, one-record threshold overflow, retained ranges, and `json-file` suffix-to-record ordering;
- non-blocking delivery under a controlled two-second Unix-stream sink stall, including guest write completion before sink release, observable dropped-new gaps, order, uniqueness, and final-record loss; and
- Docker Compose foreground output for `json-file`, `none`, and cache-disabled `syslog`, proving that early stdout/stderr remains visible exactly once even when later historical reads are unsupported.

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

## Determinism And Cleanup

Each Engine probe uses a unique `cc-log-oracle-*` container name and force-removes every tracked container in a `finally` path. The pressure probe uses exact, unique socket, PID, and result paths inside the Colima VM; it validates and removes all three without broad process matching. Each foreground probe uses a unique Compose project and host temporary directory, runs `down --volumes --remove-orphans`, and verifies that its container and default network no longer exist. Cleanup is verified before the script exits. The remaining syslog probes target unused loopback UDP ports and create no persistent Docker networks or volumes.

Volatile container IDs and the pressure socket in inspect data are replaced with placeholders, valid JSON timestamps are replaced with `<rfc3339-nano-utc>`, and raw JSON records are sorted by stream. Docker may vary transport chunk boundaries and scheduling between stdout and stderr, so the fixture preserves byte order within each stream while intentionally not asserting cross-stream order or chunk boundaries.

Every top-level case records a raw `time.monotonic` duration in the machine-readable fixture. Strict comparison reports each fresh duration, ignores ordinary timing variance when comparing semantic JSON, and fails when a fixture times out or takes at least ten times its committed baseline. Candidate captures written with `--output` retain the raw values.

The oracle does not provision external logging services or installed logging plugins. The non-reader coverage is limited to Docker's built-in `syslog` path, its local dual-logging cache, and a local controlled receiver; cloud-driver delivery, wire-level remote payloads, blocking slow-sink backpressure, dual-cache rotation under sustained load, and plugin lifecycle behavior require separate focused oracles. The exact non-blocking delivered count and marker set are also not frozen: three back-to-back calibrations preserved order and uniqueness and always dropped records, but the final delivered marker varied between 315, 565, and 576 because daemon scheduling and kernel buffering are observable inputs. The fixture therefore freezes only deterministic pressure invariants; exact ring capacity, drop-new admission, and close-drain mechanics remain covered by the pinned Moby source-level contract and implementation tests rather than an unstable black-box count.
