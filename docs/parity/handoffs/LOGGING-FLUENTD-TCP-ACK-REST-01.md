# LOGGING-FLUENTD-TCP-ACK-REST-01 Handoff

## State

`Queued` — the Docker reference, fork-only source correction, focused transport suite, and focused coverage are checkpointed. [RUNTIME-ISOLATED-PUBLIC-SOCKET-01](RUNTIME-ISOLATED-PUBLIC-SOCKET-01.md) now proves a namespace-aware candidate can start and stop without interrupting the user-owned `devcontainer-engine`. This Fluentd contract remains unverified until its own public-socket candidates and timing evidence pass.

## User-visible contract

An unmodified Docker CLI creates a cache-disabled Fluentd TCP container using `host.docker.internal`, selected `tag`, `env`, `labels`, `fluentd-request-ack`, and `fluentd-sub-second-precision` options. A bounded host receiver observes the Docker Fluent Forward MessagePack records for ordered stdout, binary stdout, and stderr output; sends each chunk acknowledgement; verifies the Docker unreadable-remote-history error; and proves cleanup. The matching candidate must retain the Docker-facing alias and TLS identity while routing its native macOS TCP connection to loopback.

## Explicit non-goals

This contract does not certify Fluentd TLS trust, Unix transport, async/retry/buffer/backpressure behavior, dual-cache behavior, full failure/migration/security matrices, other remote drivers, Testcontainers or devcontainer clients, synchronized publication, or release-grade comparable-or-better performance.

## Pinned Docker oracle

Same-MBP Docker CLI `29.7.1`, Docker Engine `29.2.1`, Colima, and `alpine:3.20`. The retained marker-protected root `/private/tmp/container-rest-fluentd.default-host-v2.vGmC8z` contains the Docker reference result (`ffd4198d884af60244d747017aac0aae5ae60c9eefba9b24a76e82595046556e`) and receiver result (`51ed8065d8427c94f4273986814cc9feb318f306d18b64c195d2473ecee0c69b`). `Tools/parity/check-docker-rest-fluentd-contract.sh --reference --strict --work-root /private/tmp/container-rest-fluentd.default-host-v2.vGmC8z --retain-work-root --result /private/tmp/container-rest-fluentd.default-host-v2.vGmC8z/result.json` passed in `0.42431754095014185` seconds: two receiver connections, three accepted EventTime records, three acknowledgements, ordered stdout/stdout/stderr sources, selected `fluentd-rest.<name>` tag and metadata, receiver peer close, no timeout, and no receiver errors.

## Affected repositories and inputs

- `container-compose` `main` at signed `2677fd8378aa4512a68d1ebe56468c3ff9faa484` adds `Tools/parity/check-docker-rest-fluentd-contract.sh` (SHA-256 `34d61d128ef9f000c2b94158ceb5ecc5e264603ed633ec0609e8bc58309a18a2`).
- `container` local `upstream/logging-driver-parity` at signed `d67b614ebd7e0c1fade908c4a5ab6e48b751e393` maps the Docker VM alias only at the native macOS Fluentd TCP dial boundary and keeps the original configured host for TLS identity verification.
- `containerization` local `upstream/engine-linux-sandbox` at `38d9c695e7a6915e5ce45d12c893dc323a661af7` and Engine API local `main` at `4949e743675f00ec102f7acacdb4e990409e383f` are the exact focused-test dependency inputs. No published pin moved.

## Focused proof

The fresh scratch-root `tcpDockerHostAliasRoutesToNativeLoopbackAndDrainsAcknowledgement` regression passes after a complete build of the exact local source/dependency graph. The full `FluentdNIOTransportLoopbackTests` suite passes `12/12`, covering TCP, ACK, native alias, Unix transport, TLS identity, timeout, and reconnect boundaries. The instrumented run under `/private/tmp/container-fluentd-coverage.8f9tZu` reports `NIOFluentdTransport.swift` at `478/518` lines (`92.28%`) and `43/44` functions (`97.73%`). The new `nativeConnectionHost` helper executed both alias and fallback paths. `swift format lint --strict`, `bash -n`, ShellCheck, and `git diff --check` pass for the changed source, test, and CLI fixture.

## Completion criteria

Two fresh exact-fingerprint candidate public-socket runs must match the retained Docker contract for MessagePack wire types, tag/metadata, ACK handling, lifecycle/inspect state, unreadable history, native authority visibility, and cleanup. Each run must bind source SHA, direct dependency revisions, built binary, guest/init image, harness, and marker-protected root into one certificate. Paired timings must be retained for the contract and feed the broader comparable-or-better release evidence; neither public candidate nor performance certificate exists yet.

## Blocker criteria

The former app-root-only safety boundary is resolved for the namespace-aware runner: `CONTAINER_SERVICE_NAMESPACE` derives every candidate service label and socket, and `system stop` scopes enumeration to that namespace. A real Fluentd wire/ACK/lifecycle/authority/cleanup mismatch, a fingerprint assembly failure, or two evidence-based corrections remains a concrete blocker. Do not run this contract through the default namespace or infer its result from the runtime prerequisite.

## Safe handoff

Keep `/private/tmp/container-rest-fluentd.default-host-v2.vGmC8z` and the earlier assertion-correction root `/private/tmp/container-rest-fluentd.default-host.X4Tui2`, both marker-protected; the fresh scratch root `/private/tmp/container-fluentd-scratch.pX2muF`; and the coverage root `/private/tmp/container-fluentd-coverage.8f9tZu`. Preserve the signed source and Compose commits above, the closed owned [Container issue #84](https://github.com/stephenlclarke/container/issues/84), [the verified namespace prerequisite](RUNTIME-ISOLATED-PUBLIC-SOCKET-01.md), and Slack START thread `1786108018.513159`. Resume with a new marker-protected namespace-aware candidate root and exact source/dependency/binary/guest/root fingerprint.

## Documentation disposition

`STATUS.md`, the Docker logging design/oracle, the slice ledger, this handoff, and issue #84 distinguish the fixed fork-only alias defect from the still-unverified public candidate. The namespace prerequisite is verified, but no Fluentd result or performance claim changed. Apple `origin/main` has no Fluentd provider at this path, so no Apple-shaped issue or pull-request handoff is applicable.
