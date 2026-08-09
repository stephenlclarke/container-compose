# LOGGING-SYSLOG-TLS-TRUST-REJECTION-06

| Field | Record |
| --- | --- |
| State | `Blocked` — Docker's contract and a narrow source correction are retained, but the correction has not yet been rebuilt into a fresh exact candidate or proven through the public socket. |
| Owner | Container-family logging parity |
| Slack START | `1786275989.673419` |

## User-visible contract

An unmodified Docker CLI creates a cache-disabled Syslog container with
`syslog-address=tcp+tls://host.docker.internal:PORT` against a bounded
self-signed TLS receiver. Create succeeds. Start fails synchronously with
Docker's exact certificate-verification diagnostic, leaves the container in
`created`, preserves the requested LogConfig, causes exactly one receiver
connection with `bad_certificate`, and removes the container and generated key
during cleanup.

## Pinned Docker oracle

The same MBP Docker CLI `29.7.1`, Engine `29.2.1`, API `1.53`, and
`alpine:3.20` reference is retained at
`/private/tmp/container-syslog-tls-probe.4Imdsj/result.json`. It accepted
create, rejected start with
`tls: failed to verify certificate: x509: certificate signed by unknown authority`,
retained `created`, and recorded `SSLV3_ALERT_BAD_CERTIFICATE`.

## Repository-owned strict fixture

Compose now retains `Tools/parity/check-docker-rest-syslog-tls-trust-failure.sh` (SHA-256 `dd2005ad3736a122f95b9daba1f2bd8ffbb0950a54352fef4b2c1cc34da5e160`). It drives the same unmodified Docker CLI against either Docker or a Container public socket and can optionally prove native authority before and after cleanup. The fixture's pinned Docker run at `/private/tmp/container-rest-syslog-tls.reference.ZiBk37/result.json` (SHA-256 `5b7ac016869e5a0588cafd0c2eadcc6ea79abb75951b883258132d98d14df9d6`) completed in `0.39233954111114144` seconds. It captured the exact start diagnostic, `created`, one receiver connection with `SSLV3_ALERT_BAD_CERTIFICATE`, the requested Syslog LogConfig, container removal, and removal of the generated private key.

## Current candidate finding

The existing isolated candidate fingerprint uses Container base
`d843dd598fa086c8572e5df8a71eece56ad7b576`, source patch
`742ffae55579857d201a624dfc6766de11fbb29e89efb05f8db3d1d9965becdd`,
Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`, and Engine API
`afb8a8f68ed56829b669c95cbddb488a68dc9175`. Its staged patch does not touch
Syslog. The retained result at
`/private/tmp/container-syslog-tls-candidate-probe.ssxkB4/result.json` reaches
the receiver and retains `created`, but reports generic
`container logging operation failed` and sends
`SSLV3_ALERT_CERTIFICATE_UNKNOWN`. Native authority exposes the requested
Syslog configuration before cleanup and no matching entry after cleanup.

## Source correction and focused validation

The local Container source worktree
`/private/tmp/container-gelf-tcp-retry-combined-01-source` adds a typed Syslog
trust-verification error, maps only BoringSSL
`CERTIFICATE_VERIFY_FAILED` handshake failures to it, and maps that error to
Docker's exact start diagnostic. Its parser and strict format checks pass for
the touched provider and test files. A copy-on-write focused release test stage
stalled in SwiftPM manifest setup before compilation, so it was stopped and
removed. This is a functional build-proof blocker, not a performance decision.

## Fresh candidate rebuild attempt

The marker-protected root
`/private/tmp/ctr-syslog-tls-archive.FaYEnp` records the next exact rebuild
attempt. It started from signed Container `72d3b573`, clean local
Containerization `38d9c695`, Engine API `afb8a8f`, and the local SwiftNIO SSL
alert-control checkout `a9d6485`. The source worktree and retained TLS build
cache were separated with APFS reflinks; the no-resolution graph correctly
selected the two current filesystem dependencies and retained the NIOSSL edit.

The inherited SwiftPM workspace first contained obsolete editable Engine API
and Containerization records. Recreating only the disposable workspace from
the cached repositories fixed that graph mismatch. The release build then
reached `1388/1408` compile actions but exhausted the MBP filesystem while
writing the relocated Swift module cache (`No space left on device`). It
produced no archive, packaged binary, runtime, or public-socket result, so it
is not candidate evidence. The disposable source worktree was removed after
all candidate processes exited, restoring the available space; its archive
build logs and pre-rebuild workspace/lock snapshots remain under the retained
marker root.

## Missing acceptance evidence

Before changing this state, build a fresh exact candidate with the source correction and local SwiftNIO SSL alert-control dependency, then run two independent public-socket samples through the repository-owned strict fixture. Each must match Docker's start diagnostic, `created` state, requested LogConfig, `bad_certificate` alert, cleanup, native authority state, and user-runtime health. Do not reuse the earlier candidate.

## Safe handoff

Preserve the Docker and candidate roots above, the immutable build stage
`/private/tmp/container-tls-alert-stage.5h9L5d`, the failed-rebuild record
`/private/tmp/ctr-syslog-tls-archive.FaYEnp`, the strict Docker fixture root
`/private/tmp/container-rest-syslog-tls.reference.ZiBk37`, and the existing
GELF candidate service. Reclaim sufficient disk for a full relocated module
cache before creating another marker-protected candidate root. Do not restart
the user runtime, move dependency pins, or treat ordinary duration as a
blocker. Resume only with a new marker-protected candidate root and an
independently captured result.
