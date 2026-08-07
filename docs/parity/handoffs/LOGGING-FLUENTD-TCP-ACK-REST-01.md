# LOGGING-FLUENTD-TCP-ACK-REST-01 Handoff

## State

`Verified` — narrow cache-disabled Fluentd TCP public-socket behavior. Two fresh namespace-isolated candidates now match the retained Docker wire, acknowledgement, identity, history, lifecycle, authority, and cleanup contract. This does not certify the complete Fluentd driver or comparable-or-better release performance.

## User-visible contract

An unmodified Docker CLI creates a cache-disabled Fluentd TCP container using `host.docker.internal`, selected `tag`, `env`, `labels`, `fluentd-request-ack`, and `fluentd-sub-second-precision` options. A bounded host receiver observes the Docker Fluent Forward MessagePack records for ordered stdout, binary stdout, and stderr output; sends each chunk acknowledgement; verifies the Docker unreadable-remote-history error; and proves cleanup. The matching candidate must retain the Docker-facing alias and TLS identity while routing its native macOS TCP connection to loopback.

## Explicit non-goals

This contract does not certify Fluentd TLS trust, Unix transport, async/retry/buffer/backpressure behavior, dual-cache behavior, full failure/migration/security matrices, other remote drivers, Testcontainers or devcontainer clients, synchronized publication, or release-grade comparable-or-better performance.

## Pinned Docker oracle

Same-MBP Docker CLI `29.7.1`, Docker Engine `29.2.1`, Colima, and `alpine:3.20`. The retained marker-protected root `/private/tmp/container-rest-fluentd.default-host-v2.vGmC8z` contains the Docker reference result (`ffd4198d884af60244d747017aac0aae5ae60c9eefba9b24a76e82595046556e`) and receiver result (`51ed8065d8427c94f4273986814cc9feb318f306d18b64c195d2473ecee0c69b`). `Tools/parity/check-docker-rest-fluentd-contract.sh --reference --strict --work-root /private/tmp/container-rest-fluentd.default-host-v2.vGmC8z --retain-work-root --result /private/tmp/container-rest-fluentd.default-host-v2.vGmC8z/result.json` passed in `0.42431754095014185` seconds: two receiver connections, three accepted EventTime records, three acknowledgements, ordered stdout/stdout/stderr sources, selected `fluentd-rest.<name>` tag and metadata, receiver peer close, no timeout, and no receiver errors.

## Affected repositories and inputs

- `container-compose` `main` at `acae2e3dfe5ddda86a2bf498160aab630bef16ce` supplies `Tools/parity/check-docker-rest-fluentd-contract.sh` (SHA-256 `34d61d128ef9f000c2b94158ceb5ecc5e264603ed633ec0609e8bc58309a18a2`) and the namespace-aware wrapper (SHA-256 `7a396d8626a0e37c1b7f71e732674baebd1b3752bedc3378a7e4510e3323987f`).
- `container` local `upstream/logging-fluentd-tcp-ack-rest-01` at `359e14e4f991db0f3729d44651b9f82d9ab1b0ed` contains the earlier `d67b614e` native alias dial correction and normalizes the Docker API name to the leading-slash Fluent Forward `container_name` value without changing the bare `{{.Name}}` tag expansion.
- `containerization` local `upstream/engine-linux-sandbox` at `38d9c695e7a6915e5ce45d12c893dc323a661af7` was staged and source-built into the guest; Engine API local `upstream/logging-fluentd-container-wait-01` is `f5d0d120bb139675e96a4ef9f7b0ac800827c295`. The resulting engine declaration reports package version `0.3.5` and its embedded runtime revision `77f06d4c44341e04241941072fb69e2b85a6f5c1`; the retained staged-source fingerprint records the source-built guest revision. No published pin moved.

## Focused proof

The retained `tcpDockerHostAliasRoutesToNativeLoopbackAndDrainsAcknowledgement` regression and `FluentdNIOTransportLoopbackTests` `12/12` prove the native dial boundary. The current `FluentdConfigurationTests` focused run passes `8/8` with the exact local semantic helper; its new bare-runtime-name regression verifies `/web` in the Forward record while the tag remains `web`. The changed executable line ran 13 times, exceeding the 90% changed-code target. `swift format lint --strict` and `git diff --check` pass for the correction and test; the fixture also passes syntax and ShellCheck.

## Completion criteria

Met. The certificate at `/private/tmp/container-rest-fluentd.candidate-name-359.6UnO7v/FINGERPRINT-COMPLETE.json` binds the clean source/dependency graph, signed candidate binary (`94c46b4b…`), source-built guest archive (`5d420113…`), harness, wrapper, Docker oracle, two distinct marker-protected candidate roots, result/receiver/log hashes, and postflight cleanup. Candidate 1 passed in `2.768545625s` (`6.525×` Docker) and candidate 2 in `2.345302459s` (`5.527×`); each received three ordered EventTime records, sent three ACKs, reported no receiver errors, rejected remote history as Docker does, and stopped only its own namespace. Both are below the focused 10× functional guard. Neither timing is comparable or better than Docker, so the separate release-performance requirement remains open.

## Blocker criteria

Not reached for this narrow contract. The namespace-aware runner derives every candidate service label and socket from `CONTAINER_SERVICE_NAMESPACE`, and `system stop` scopes enumeration to that namespace. The two initial harness-only setup failures were retained and corrected before the fixture began; neither exercised a Fluentd assertion. Do not use this result to infer Fluentd TLS, Unix, async/retry/buffer, external-client, migration/security, or release-performance behavior.

## Safe handoff

Keep the Docker root `/private/tmp/container-rest-fluentd.default-host-v2.vGmC8z`, source-guest root `/private/tmp/ctr-fluentd-guest-359-bootstrap.7VWfQA`, candidate roots `/private/tmp/ctr-fluentd-name-359.FGmIiu` and `/private/tmp/ctr-fluentd-name-359.iwMbBz`, fixture roots `/private/tmp/container-rest-fluentd.candidate-name-359.6UnO7v` and `/private/tmp/container-rest-fluentd.candidate-name-359.y9TRQi`, and the common exact-fingerprint certificate above. Preserve the signed source and Compose commits, the closed owned [Container issues #84](https://github.com/stephenlclarke/container/issues/84) and [#86](https://github.com/stephenlclarke/container/issues/86), [the verified namespace prerequisite](RUNTIME-ISOLATED-PUBLIC-SOCKET-01.md), and Slack START thread `1786123301.422779`. Resume a separate Fluentd gap only from a new marker-protected root and a new Docker oracle where the behaviour differs.

## Documentation disposition

`STATUS.md`, the Docker logging design/oracle, the slice ledger, this handoff, and issues #84 and #86 now distinguish the verified narrow public Fluentd TCP/ACK contract from the remaining Fluentd and programme performance gaps. Apple `origin/main` has no Fluentd provider at this path, so no Apple-shaped issue or pull-request handoff is applicable.
