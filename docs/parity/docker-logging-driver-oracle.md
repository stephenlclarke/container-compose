# Docker Logging-Driver Oracle

This oracle records the Docker Engine behavior that the logging-driver implementation must reproduce. It is a focused Engine API reference, not a test of the `container-compose` implementation.

The committed fixture is pinned to Docker Engine 29.2.1, API 1.53, the active `colima` context on arm64 macOS, and a preloaded `alpine:3.20` image. The fixture records the image repository digest observed during capture so that an image change is visible in review.

## Covered Semantics

The capture covers:

- omitted `HostConfig.LogConfig` resolving to the daemon's `json-file` default;
- explicit `json-file`, `local`, `none`, and `syslog` driver identities and arbitrary option preservation, including Engine acceptance of options on `none`;
- create-time option-name rejection versus start-time option-value rejection, including container residue and inspect state;
- `HostConfig.LogConfig`, `LogPath`, stopped-container reads, restart retention, and the effect of a created-container follow read;
- non-TTY stdout/stderr selection and Docker's eight-byte multiplex framing;
- TTY raw, merged output and stream-filter behavior;
- raw `json-file` record keys, streams, labels, and RFC 3339 nanosecond timestamp shape;
- native-reader behavior for `local`; and
- the default dual-logging cache and `cache-disabled=true` behavior for the non-reader `syslog` driver.

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

Each run uses unique `cc-log-oracle-*` container names and force-removes every tracked container in a `finally` path. Cleanup is verified before the script exits. The syslog probes target unused loopback UDP ports and create no Docker networks or volumes.

Volatile container IDs in `LogPath` are replaced with `<container-id>`, valid JSON timestamps are replaced with `<rfc3339-nano-utc>`, and raw JSON records are sorted by stream. Docker may vary transport chunk boundaries and scheduling between stdout and stderr, so the fixture preserves byte order within each stream while intentionally not asserting cross-stream order or chunk boundaries.

The oracle does not provision external logging services or installed logging plugins. The non-reader coverage is limited to Docker's built-in `syslog` path and its local dual-logging cache; cloud-driver delivery, remote receiver payloads, rotation under sustained load, blocking/backpressure, and plugin lifecycle behavior require separate focused oracles.
