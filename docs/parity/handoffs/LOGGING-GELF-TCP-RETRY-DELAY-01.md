# LOGGING-GELF-TCP-RETRY-DELAY-01 Handoff

## State

`Queued` — the implementation and focused evidence are checkpointed, and [RUNTIME-ISOLATED-PUBLIC-SOCKET-01](RUNTIME-ISOLATED-PUBLIC-SOCKET-01.md) now verifies a candidate-only namespace/socket lifecycle with the user-owned `devcontainer-engine` healthy. This delayed-retry contract remains unverified until its own public-socket candidates and timing evidence pass; the prior single-reconnect and zero-budget certificates do not prove the complete GELF retry matrix.

## User-visible contract

The unmodified Docker CLI creates a cache-disabled TCP `gelf` container with a positive `gelf-tcp-max-reconnect` budget and non-zero `gelf-tcp-reconnect-delay`. A bounded receiver forces successive peer resets, records Docker's retry timing and delivery/disposition for each record, and verifies the terminal replacement stream, lifecycle, inspect projection, native authority visibility, and cleanup through Docker Engine 29.2.1 and the candidate public socket.

## Explicit non-goals

This contract does not certify blocking slow-sink backpressure, all retry budgets or provider errors, UDP behavior, dual-cache pressure, other drivers, plugins, migration, security, external clients, devcontainer adoption, release publication, or the programme-wide comparable-or-better performance matrix.

## Pinned Docker oracle

Same-MBP Docker CLI `29.7.1`, Docker Engine `29.2.1` (API `1.53`), Colima, and `alpine:3.20`. The post-hardening default-address reference is retained at `/private/tmp/container-rest-gelf.default-host.wG4HQt`: `Tools/parity/check-docker-rest-gelf-contract.sh --transport tcp --scenario tcp-retry-delay --reference --strict` passed in `22.447226208` seconds with result SHA-256 `ecb6fc023506a605c360f4032a59a26138daa0898d3dfd2db3e1c7ac1f363abe`. Its receiver result SHA-256 is `d5648af97613f52d51b028dc07d168f0c369062644673f6e4ecd7b30811bedf0`; it records four accepted connections, two one-frame forced resets, delay intervals `10.019107917` and `9.010752833` seconds, a terminal recovery record, peer close, and no timeout. The repository-owned Bash CLI fixture uses its default `host.docker.internal` log address and now rejects a symlinked `--work-root` before it can touch fixture state.

## Affected repositories and inputs

- `container-compose` `main` at `c9660d308925ca1f72cb8ab8b72adbcc00a0de22`: hardened Docker CLI fixture and retained contract evidence.
- `container` local `upstream/logging-driver-parity` at signed `45bbfb00542d9d91598356ce7dd8c3c6ad2be374`: Engine-Linux TCP relay, session/transport/authority integration, and focused regressions.
- `containerization` local `upstream/engine-linux-sandbox` at `38d9c695e7a6915e5ce45d12c893dc323a661af7` and Engine API local `main` at `4949e743675f00ec102f7acacdb4e990409e383f`: exact dependency inputs unless the focused diagnosis proves a lower-layer change is necessary.

## Focused proof

The fresh Docker reference is captured. The prior candidate diagnostic used literal `127.0.0.1`, a failed endpoint-scope assumption: the new TCP relay runs in Engine Linux, while Docker and the relay both need `host.docker.internal` to reach the host receiver on macOS. The fixture now defaults to that Docker-compatible bridge alias without rewriting an explicit caller address, and the repository-owned Bash fixture has a fresh retained Docker delayed-retry reference after its symlink-safe work-root hardening.

The sealed Linux/arm64 service lane now passes `make test-gelf-service`: `gofmt`, `go vet`, race-enabled tests, deterministic workload-manifest comparison, and the enforced 90% coverage gate at 90.5% statements. The exact current service archive SHA-256 is `734f01e0fdcf246626d84ef6ceb58b9ff921f12cdd6875553ac8b67dc0a10bc4` and its manifest SHA-256 is `739d761b4bfed653bb0e19709762daeda7528be0c2fd7b27054f76fdeb067f91`. The real-asset acceptance path copies the archive and manifest to a marker-protected `/private/tmp/container-gelf-service-swift.*` root and uses a second marker-protected SwiftPM `--scratch-path`, so neither the generated asset nor another workstream's build products can be read or removed. On the exact local graph, `CONTAINERIZATION_PACKAGE_PATH=/Users/sclarke/Documents/container/containerization-engine-sandbox CONTAINER_ENGINE_API_PACKAGE_PATH=/Users/sclarke/github/container-engine-api CONTAINERIZATION_REF=38d9c695e7a6915e5ce45d12c893dc323a661af7 ./scripts/test-gelf-service-asset.sh --asset-directory bin/services/container-gelf-service` passed all 17 `EngineLinuxSandboxGELFTCPServiceTests`, including acceptance of the copied configured archive/manifest and re-verification of the copied artifact. The exact local Containerization `38d9c695…` and Engine API `4949e743…` graph also has focused `GELFTCPServiceWireTests` (8), provider-set TCP injection (7), and `GELFSessionTests` (16) proof. A connected stale service identity is terminal rather than an availability retry, so the connector cannot accidentally retry a substituted service. The relay rejects a partial remote write rather than reporting it as delivered, and the Swift wire client invalidates a partial service receipt as `transportClosed`, preserving `GELFSession` as the single reconnect/replay authority. The measured service-policy/materializer source is 93.70% lines and 93.33% functions under `/private/tmp/container-gelf-coverage.VDsD76`; the production host-XPC resolver adapter is an explicit runtime-only coverage exception until the safe candidate lane can exercise it. The checked-in remote Containerization `0.3.5` lacks `WorkloadNetworkEndpoint` and is not an exact candidate graph; the ordinary remote-graph asset target therefore is not used as candidate evidence. `Package.resolved` was restored after the local overlay. A live candidate still must prove that the authority materializes this staged artifact in the Engine-Linux guest. Before that validation, retain a marker-protected root that fingerprints source revisions, dependency paths, built binaries, guest/init image, harness, wrapper, Docker oracle, result files, and cleanup.

## Completion criteria

- The Docker reference supplies a stable observable delayed-retry contract.
- The exact candidate matches the observed configuration, record ordering/disposition, connection/retry behavior, lifecycle/inspect state, native authority, and cleanup in two independent public-socket runs.
- Changed production code has at least 90% focused line coverage, with the host-XPC resolver exception retained explicitly, and the repository-owned Bash CLI fixture passes `bash -n`, `shellcheck`, plus the focused Docker and candidate runs.
- A clean immutable local checkpoint records the exact evidence and does not claim comparable-or-better performance outside the declared fixture.

## Blocker criteria

If Docker does not yield a deterministic delayed-retry observable, or two evidence-based corrections leave a candidate mismatch unexplained, retain the oracle, exact fingerprints, failure logs, and this record as `Blocked` or `Handed off` rather than repeating runtime attempts. The former safety blocker is resolved only for namespace-aware candidates: `CONTAINER_SERVICE_NAMESPACE` scopes launchd/Mach labels and `system stop` to the selected root-derived namespace. A default-namespace candidate remains invalid evidence, and no candidate or performance claim is made yet.

## Safe handoff

Keep all existing GELF evidence roots unchanged, including `/private/tmp/container-gelf-coverage.VDsD76` and the fresh Docker root `/private/tmp/container-rest-gelf.default-host.wG4HQt` (`.container-rest-gelf-root`, `result.json`, receiver streams, receiver result, and cleanup markers). The transient failed asset root `/private/tmp/container-gelf-service-swift.U9SXnz` was moved to Trash after its marker was verified; no retained evidence root was deleted. Preserve signed Container `45bbfb00542d9d91598356ce7dd8c3c6ad2be374`, Compose `c9660d308925ca1f72cb8ab8b72adbcc00a0de22`, the two local upstream handoff documents, [the verified namespace prerequisite](RUNTIME-ISOLATED-PUBLIC-SOCKET-01.md), and Slack START thread `1786082321.541849`. Resume with a fresh marker-protected namespace-aware candidate root and fingerprint the exact source/dependency/binary/guest/root graph before the two candidate runs. Do not infer complete GELF or logging-driver closure from this slice.

## Documentation disposition

This handoff, `STATUS.md`, the Docker logging oracle, the slice ledger, the logging design, and the paired local Apple-shaped Container issue/PR records were reviewed for this checkpoint. They now record the fresh Docker oracle, the signed implementation and exact asset proof, and the unrun public-candidate/performance boundary; no broader logging, migration, security, external-client, or release-performance claim changed.
