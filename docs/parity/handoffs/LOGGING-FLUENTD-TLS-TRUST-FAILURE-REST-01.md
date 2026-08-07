# LOGGING-FLUENTD-TLS-TRUST-FAILURE-REST-01

| Field | Record |
| --- | --- |
| State | `Blocked` — the Container source correction now matches Docker's public rejection diagnostic, phase, and rejected state, but the Darwin NIOSSL verification callback still sends `certificate_unknown` where the Docker oracle sends `bad_certificate`. The remaining dependency boundary is handed off to a local `upstream/` SwiftNIO SSL patch; this contract is not `Verified`. |
| Owner | Container-family logging parity |
| Slack START | `1786132081.281259` |

## User-visible contract

An unmodified Docker CLI creates a cache-disabled Fluentd container with `fluentd-address=tls://host.docker.internal:PORT` against a bounded host-side self-signed TLS receiver. Create accepts the configuration. Start must fail synchronously at the Docker-matched logging-initialization phase, leave the container in `created`, preserve the requested Fluentd configuration in inspection, cause the receiver to observe a TLS trust-rejection alert, and leave no container, receiver, candidate service, socket, or marker-root residue after cleanup. The native candidate must route only its dial target to loopback while retaining `host.docker.internal` as the TLS identity.

## Explicit non-goals

This failure-only contract does not certify trusted Fluentd TLS delivery, custom trust roots, successful SNI/identity behavior, decrypted Fluent Forward payloads, Unix transport, async/retry/buffer/backpressure behavior, dual-cache behavior, full failure/migration/security matrices, external clients, synchronized publication, or comparable-or-better release performance.

## Pinned Docker oracle

Same-MBP Docker CLI `29.7.1`, Engine `29.2.1`, API `1.53`, and `alpine:3.20` are the behavioral oracle. The fresh retained result at `/private/tmp/container-rest-fluentd-tls.docker.m7QDss/result.json` passed in `0.31440287502482533` seconds (SHA-256 `ce8ad3a5048ba86f9a162d109e1dd1b2eceda667e1d61ec26558565c584b9d14`). It accepts create with HTTP `201`, rejects start with HTTP `500`, retains `created`, reports `failed to create task for container: failed to initialize logging driver: tls: failed to verify certificate: x509: certificate signed by unknown authority`, removes the exact container, and records `SSLV3_ALERT_BAD_CERTIFICATE` at the bounded self-signed receiver.

## Exact affected graph

Compose starts at signed `2d3307c47e112ea3bd0043302e7911e274dada98`; the strict Bash fixture now has SHA-256 `bcfca0e581afa8f17f55c48e307c3fd04305b4eb275371b85932c218067e7221`; Container source is signed `66e0cac3c7e86147d3cb5e26c5dc68fe2a987d4f`; Containerization is `38d9c695e7a6915e5ce45d12c893dc323a661af7`; Engine API is `f5d0d120bb139675e96a4ef9f7b0ac800827c295`; and transitive `apple/swift-nio-ssl` is `d930168b86f46ca51a4bc09c5ca45c1833db8067`. No published dependency pin moves as part of this contract.

## Focused proof

The repository-owned Bash fixture exercised the same unmodified Docker CLI path for the fresh Docker reference and the exact-fingerprint candidate. The direct TLS transport regression covers the observed trust-rejection mapping and preserves the requested hostname: `FluentdNIOTransportLoopbackTests` passed 13 focused cases and `ContainerLoggingStartErrorTests` passed four. The candidate's exact source/dependency/binary/guest/fixture/root certificate is retained at `/private/tmp/container-fluentd-runtime-stage-66e.FjAkAu/candidate-run-1.inputs.txt`; it records source `66e0cac3`, the staged binary SHA-256 `a38aa0213bdc0e1ddebc80011ad9a06dc0be225c978572bb907a60187be15729`, guest SHA-256 `5d4201135affb9bb0ce34ebcb184551689a214d3118b75564a8fa498667d77f6`, and user-runtime `29.7.1/29.2.1` before and after. Bash syntax validation and ShellCheck pass for the fixture at this checkpoint.

## Completion criteria

One fresh Docker reference and two independent candidates after the NIOSSL alert correction must bind source SHA, dependency revisions, binary, guest/init archive, fixture, receiver certificate material, and marker-protected root into retained evidence. Each must match configuration acceptance, start failure phase, created state, normalized error class/message, receiver alert, container removal, receiver exit, namespace-scoped service cleanup, and user-runtime health. Timing is retained only for the broader release comparison and is not comparable-or-better proof by itself. The first candidate is retained as a failing diagnostic: it matches the exact Docker start error and `created` state, but it does not count toward the two candidates because its receiver saw `SSLV3_ALERT_CERTIFICATE_UNKNOWN`.

## Blocker criteria

The first fresh candidate reached a real trust-alert mismatch. Its raw evidence root is `/private/tmp/container-rest-fluentd-tls.candidate-66e-1.tBR6n1`: `start.stderr` SHA-256 `a347f529697a6b0a6bd5c90eff830ba04315d91ebb6953a8732c5cdd058098af` contains Docker's exact diagnostic, `inspect-after-start.json` SHA-256 `884a6fa3e1896360f3d81830887a9078167391fd3c58ba65ab8c72417a667578` records `created`/exit `128`, and `receiver-result.json` SHA-256 `9432a6398af41d246301a3af92aba6edcdd3d890f3442decac26fb641169c9f4` records one rejected connection with `SSLV3_ALERT_CERTIFICATE_UNKNOWN`. The synthetic receiver private key is absent and the wrapper stopped only its candidate namespace while the user runtime remained healthy. NIOSSL's Darwin `SSL_set_custom_verify` bridge ignores BoringSSL's `outAlert` argument and therefore retains BoringSSL's default `certificate_unknown`. Do not mutate Docker, candidate, or host trust stores to make this failure contract pass.

## Safe handoff

Preserve the Docker root, failing candidate fixture root, candidate application root `/private/tmp/ctr-fluentd-tls-66e-1.7TlDKA`, and immutable build stage `/private/tmp/container-fluentd-runtime-stage-66e.FjAkAu`. The next active contract is a local SwiftNIO SSL Darwin alert-control patch on an `upstream/` branch, with its own focused NIOSSL test and Apple-shaped handoff. Only after that patch is built through Container may this contract resume with two new marker-protected candidates. Do not reuse the TCP/ACK roots or infer TLS failure behavior from existing component tests.
