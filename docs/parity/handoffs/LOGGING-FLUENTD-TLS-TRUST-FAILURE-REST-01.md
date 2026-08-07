# LOGGING-FLUENTD-TLS-TRUST-FAILURE-REST-01

| Field | Record |
| --- | --- |
| State | `Verified` — the two fresh release candidates now match Docker's public rejection diagnostic, phase, rejected state, `bad_certificate` alert, cleanup, and user-runtime health. The Darwin NIOSSL correction remains an unpublished Apple-shaped local handoff. |
| Owner | Container-family logging parity |
| Slack START | Original TLS contract `1786132081.281259`; alert-control continuation `1786135745.826539` |

## User-visible contract

An unmodified Docker CLI creates a cache-disabled Fluentd container with `fluentd-address=tls://host.docker.internal:PORT` against a bounded host-side self-signed TLS receiver. Create accepts the configuration. Start must fail synchronously at the Docker-matched logging-initialization phase, leave the container in `created`, preserve the requested Fluentd configuration in inspection, cause the receiver to observe a TLS trust-rejection alert, and leave no container, receiver, candidate service, socket, or marker-root residue after cleanup. The native candidate must route only its dial target to loopback while retaining `host.docker.internal` as the TLS identity.

## Explicit non-goals

This failure-only contract does not certify trusted Fluentd TLS delivery, custom trust roots, successful SNI/identity behavior, decrypted Fluent Forward payloads, Unix transport, async/retry/buffer/backpressure behavior, dual-cache behavior, full failure/migration/security matrices, external clients, synchronized publication, or comparable-or-better release performance. The retained candidate durations are designed performance inputs for the post-functional optimisation phase, not a functional closure gate unless execution fails to make liveness progress.

## Pinned Docker oracle

Same-MBP Docker CLI `29.7.1`, Engine `29.2.1`, API `1.53`, and `alpine:3.20` are the behavioral oracle. The fresh retained result at `/private/tmp/container-rest-fluentd-tls.docker.m7QDss/result.json` passed in `0.31440287502482533` seconds (SHA-256 `ce8ad3a5048ba86f9a162d109e1dd1b2eceda667e1d61ec26558565c584b9d14`). It accepts create with HTTP `201`, rejects start with HTTP `500`, retains `created`, reports `failed to create task for container: failed to initialize logging driver: tls: failed to verify certificate: x509: certificate signed by unknown authority`, removes the exact container, and records `SSLV3_ALERT_BAD_CERTIFICATE` at the bounded self-signed receiver.

## Exact affected graph

Compose signed `17822a323ac2e7a12078adfd4b8a2921b4169205` supplies the strict Bash fixture at SHA-256 `bcfca0e581afa8f17f55c48e307c3fd04305b4eb275371b85932c218067e7221` and wrapper SHA-256 `7a396d8626a0e37c1b7f71e732674baebd1b3752bedc3378a7e4510e3323987f`. Container source is signed `4933786122ea2e62069d0fbaa6eccc41925bd2ba`; Containerization is `38d9c695e7a6915e5ce45d12c893dc323a661af7`; Engine API is `f5d0d120bb139675e96a4ef9f7b0ac800827c295`; and local `apple/swift-nio-ssl` is signed `a9d648535c62e640d1df258a70c9117a8ddea43e`. The packaged release archive is SHA-256 `0111caa0d482a387b2da735bb9f7375ddcb4fb997e7daf01c9167e2dfbb89516`, extracted CLI SHA-256 `379cefb05fe1974e1cd4f0d9ba94619671a0ee2a96a70dde596af38848fba9b7`, source-built guest archive SHA-256 `5d4201135affb9bb0ce34ebcb184551689a214d3118b75564a8fa498667d77f6`, and bootstrap OCI archive SHA-256 `c714ab7421c71cebdfd0236c5a1af4b1e9af3da1855946cf3350a384491815f0`. No published dependency pin moved.

## Focused proof

The repository-owned Bash fixture exercised the same unmodified Docker CLI path for the fresh Docker reference and two independent exact-fingerprint candidates. SwiftNIO SSL strict format plus seven focused manager/bridge/Darwin integration cases pass with every new executable Swift line hit; the C shim asserts TLS alert `42` (`bad_certificate`). The packaged candidate and all build inputs are retained under `/private/tmp/container-tls-alert-stage.5h9L5d/fingerprints/`. The two public certificate results are `/private/tmp/container-rest-fluentd-tls.candidate-alert-release4.TepPNc/result.json` (`2.637404042063281s`) and `/private/tmp/container-rest-fluentd-tls.candidate-alert-release5.EyN9pZ/result.json` (`1.2239124169573188s`). Each records its source/dependency/binary/guest/fixture/root fingerprint, one `SSLV3_ALERT_BAD_CERTIFICATE` receiver result, the Docker-matched `created`/exit-`128` rejection, cleanup, and unchanged Docker CLI `29.7.1` / Engine `29.2.1` user runtime.

## Completion criteria

Met: one fresh Docker reference and two independent candidates after the NIOSSL alert correction bind source SHA, dependency revisions, binary, guest/init archive, fixture, receiver certificate material, and marker-protected root into retained evidence. Each matches configuration acceptance, start failure phase, `created` state, normalized error class/message, receiver alert, container removal, receiver exit, namespace-scoped service cleanup, and user-runtime health. Timing is retained only for the later release comparison and is not comparable-or-better proof by itself. The earlier candidate remains a failing diagnostic: it matched the exact Docker start error and `created` state, but did not count because its receiver saw `SSLV3_ALERT_CERTIFICATE_UNKNOWN`.

## Blocker criteria

Resolved. The first fresh candidate reached a real trust-alert mismatch. Its raw evidence root is `/private/tmp/container-rest-fluentd-tls.candidate-66e-1.tBR6n1`: `start.stderr` SHA-256 `a347f529697a6b0a6bd5c90eff830ba04315d91ebb6953a8732c5cdd058098af` contains Docker's exact diagnostic, `inspect-after-start.json` SHA-256 `884a6fa3e1896360f3d81830887a9078167391fd3c58ba65ab8c72417a667578` records `created`/exit `128`, and `receiver-result.json` SHA-256 `9432a6398af41d246301a3af92aba6edcdd3d890f3442decac26fb641169c9f4` records one rejected connection with `SSLV3_ALERT_CERTIFICATE_UNKNOWN`. The narrow local SwiftNIO SSL patch propagates the configured alert only through the Darwin internal verifier; public custom verifier paths retain BoringSSL's unspecified alert. The synthetic receiver private key remains absent and the wrapper stops only its candidate namespace. Do not mutate Docker, candidate, or host trust stores to make this failure contract pass.

## Safe handoff

Preserve the Docker root, historical failing candidate root, passing candidate roots `/private/tmp/ctr-fluentd-tls-alert-candidate-release-4.3CJgCK` and `/private/tmp/ctr-fluentd-tls-alert-candidate-release-5.bXQHXs`, and immutable build stage `/private/tmp/container-tls-alert-stage.5h9L5d`. The local SwiftNIO SSL Darwin alert-control patch is now focused-tested, built through Container, and recorded as an Apple-shaped handoff. Do not reuse these roots for a future contract; select an independent queued contract.
