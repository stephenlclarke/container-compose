# Consume the matched signal and log reliability runtime

## Context

The Phase 6 review identified three related runtime reliability boundaries:

- `ClientProcess.kill(_:)` encoded the signal XPC value with the wrong type, matching [apple/container#1941](https://github.com/apple/container/issues/1941) and [apple/container#1997](https://github.com/apple/container/pull/1997).
- Long log records can be truncated when a backward tail reader stops at a 1,024-byte chunk boundary, matching [apple/container#1967](https://github.com/apple/container/issues/1967) and [apple/container#2000](https://github.com/apple/container/pull/2000).
- A failed attached-client writer must not interrupt persistent runtime logging, matching [apple/container#2009](https://github.com/apple/container/issues/2009).

The supported fork still reproduced the signal wire mismatch. Its current `LogFileOutput` already reads until it has enough complete records, and its init-process output path already writes persistent sinks before isolating and removing failed attached clients. Those two existing behaviors lacked explicit boundary regressions.

## Required Behavior

- Port the preferred signal correction as an independently removable, signed, Apple-shaped commit.
- Cover canonical, platform-divergent, and fallback signal wire values.
- Cover a single 3 KB log line and multiple 800-byte records spanning backward-read chunks.
- Prove a failed attach sink cannot interrupt subsequent persistent log writes.
- Run one committed Compose file through Docker Compose V2 and the exact matched macOS runtime.
- Build and install the matched guest init image before selecting it in the
  isolated runtime configuration, so a cold validation store never tries to
  pull an image that only the harness can create.
- Keep Compose policy out of the runtime fork and keep the Compose change pin-, parity-, and documentation-only.

## Docker Compose V2 Oracle

The committed fixture must prove:

1. `compose attach --sig-proxy=true` forwards `SIGINT` to Linux PID 1, which records the signal and exits 42.
2. `compose logs --tail 1` returns a complete 3,008-byte record plus newline.
3. `compose logs --tail 2` returns two complete 800-byte records.
4. terminating `compose attach --sig-proxy=false` after the first output record does not prevent the second record from appearing in persisted logs.

## Compatibility Boundary

Only macOS-hosted Linux runtime behavior is in scope. Windows-specific behavior is not added. Compose continues through its existing runtime adapter and CLI relay; it gains no signal-number table, log-tail parser, or writer-fanout workaround.

The isolated runtime wrapper exports its private configuration home before
startup, but writes the `vminit` override only after the local image build and
import completes. This ordering keeps the validation runtime isolated without
making its builder depend on a not-yet-installed image.

## Source Tracking

- Runtime source fix: `stephenlclarke/container` `bb2438c1f1bee38d671bf9dd94f89f603f52041e`.
- Runtime regression coverage: `stephenlclarke/container` `26cc778b80ef847ff0fbf75579675981e5982613`.
- Fork pull request: [stephenlclarke/container#29](https://github.com/stephenlclarke/container/pull/29).
- Signed fork merge: `221fafc24ebd19502f4553e0b5d38c14be3f2b22`.
- Compose runtime pin: `e9a9c13f5f6664583f9e43fceede74ba579b9f4c`.
- Matched-runtime harness correction:
  `ae05538dc40e3e6e2698a1be06b1d01063482faf`.
- Compose parity fixture: `a0576253e25ab472eeb8c929ead304479a845c4a`.
- Connector review correction:
  `10423ea7d34d43596cfb99730aa4677112ae0b3b`.
- Apple handoff: [PR-1997.md](../apple-container/PR-1997.md).

The exact Container merge revision, Compose commits, hosted checks, Sonar
result, and Current release evidence are recorded in the paired pull-request
handoff when the slice closes.
