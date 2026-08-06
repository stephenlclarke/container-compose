# LOGGING-GELF-TCP-FAILURE-REST-01 Handoff

## State

`Verified` as a narrow Docker CLI/public-socket GELF TCP start-failure and zero-budget retry-exhaustion contract. It does not certify the complete retry/failing-sink matrix, other remote drivers, external clients, or comparable-or-better release performance.

## User-visible contract

The same unmodified Docker CLI creates a cache-disabled TCP `gelf` container against Docker Engine 29.2.1 and a fresh local Container public socket. For an initially unavailable endpoint, create succeeds and start fails with Docker's GELF initialization diagnostic; inspect retains `created`, exit code `128`, zero timestamps, the configured endpoint, and the diagnostic across authority restart. For a zero-reconnect-budget receiver that resets two peers, the current records fail without corruption or duplication while the final replacement connection carries the ordered recovery record. Both paths prove Docker option projection, metadata/tag behavior, native authority, and exact cleanup.

## Exact proof

The marker-protected root `/private/tmp/container-gelf-tcp-failure-candidate-v6.bF5VQ7` contains `FINGERPRINT-PREFLIGHT.json`, `ARCHIVE-VERIFICATION.json`, and `FINGERPRINT-COMPLETE.json`; the code-signed archive and binary hashes; guest-image, harness, and wrapper fingerprints; two focused regression logs; and four candidate result/runtime-log pairs. It binds signed Container `5e46d527391fa0830cf553c95e4be5019b82d551`, local Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`, Engine API `4949e743675f00ec102f7acacdb4e990409e383f`, and Compose `fcaeea0e23bcb455d07c3d505a577e35ad7e0744` plus the preflight working-diff SHA-256 `f72b921debe302fffc3e14068bf8fb991c589991421ac8de3f565cba80e25136`.

The Docker CLI 29.7.1 / Engine 29.2.1 unavailable-endpoint reference is retained at `/private/tmp/container-gelf-tcp-failure-reference-v1.CoOhUO/harness-tcp-unavailable-result.json` and passed in `0.072112500s`. Its candidates passed in `0.505147750s` and `0.460362292s` (7.00x and 6.38x). The retry-exhaustion reference is retained at `/private/tmp/container-gelf-tcp-failure-reference-v1.CoOhUO/harness-tcp-failure-result-4.json` and passed in `12.445434875s`; candidates passed in `13.568986042s` and `13.622602750s` (both 1.09x). The raw timings meet the fixture's 10x functional guard but remain evidence for the separate comparable-or-better performance backlog.

## Correction retained as evidence

The first candidate correctly failed start but exposed a generic diagnostic and `State.ExitCode` `0`. Signed Container `73cea53bbfa3a8711a1e9320c330e4dd7c2870fa` preserves the typed GELF connection failure and configured endpoint. Signed Container `5e46d527391fa0830cf553c95e4be5019b82d551` projects Docker exit code `128` without changing the native never-started lifecycle. `GELFTransportLoopbackTests.productionTCPConnectionFailurePreservesConfiguredEndpoint` and `ContainerLoggingAuthorityIntegrationTests.dockerRejectedStartErrorIsInspectableAfterAuthorityRestart` pass against the exact local graph.

## Remaining boundary

The full TCP retry/delay and sustained-failure matrix, slow-sink/backpressure, dual-cache pressure, migration/security/provider-failure matrices, other remote drivers, Testcontainers/devcontainer lanes, release publication, and programme-wide comparable-or-better performance proof remain queued. The unavailable-endpoint candidate is 6.38–7.00x Docker even though it remains below the fixture's functional guard. [Container issue 74](https://github.com/stephenlclarke/container/issues/74) still owns the unrelated public create name-as-ID discrepancy.

## Safe resumption

Keep the marker-protected candidate root, Docker reference root, signed Container checkpoints, the Apple-shaped handoff pair, this handoff, and Slack START thread `1785992707.844709`. Do not repeat broad gates for this completed narrow contract. Select one independent queued contract only after a Slack instruction poll.
