# Runtime Capability Contract

`container-compose` requires lower-runtime behaviour that is not available in
stock Apple releases. A source name or commit hash identifies a build, but does
not explain which contract is missing. The supported stack therefore publishes
a versioned, typed capability manifest through:

```sh
container system version --format json
container compose version --format json
```

Both commands report `runtimeCapabilitySchemaVersion` and
`runtimeCapabilities`. Compose checks these fields before every command that
needs the runtime. An absent capability, a duplicate identifier, or a schema
mismatch fails closed and names the exact problem. Additional identifiers are
accepted so a newer compatible runtime can be used safely.

## Schema And Capability Versions

The manifest schema versions the JSON contract. Increment it only for an
incompatible representation change.

Each capability identifier has its own terminal version. Increment that
version when the behaviour expected under the identifier changes
incompatibly. Add a separate identifier for an independent optional contract.
Do not silently widen an existing identifier.

The release source of truth is
`Tools/release/runtime-capabilities.json`. `make stack-consistency` verifies
that it exactly matches the typed Compose and sibling Container definitions.

## Version 1 Capabilities

| Identifier suffix | Contract covered |
| --- | --- |
| `archive-copy.v1` | Direct archive copy in both directions, metadata preservation, streaming, cancellation, and guest-path safety used by `compose cp` |
| `build-extensions.v1` | Named builders, scoped no-cache filters, SSH forwarding, attestations, external Dockerfiles, additional contexts, and checks used by `compose build` |
| `create-configuration.v1` | Typed process, mount, network, resource, namespace, security, device, and GPU configuration used when creating service and one-off containers |
| `image-filesystem.v1` | Image metadata and declared-volume discovery, image-volume copy-up, commit/export, and live snapshot behaviour |
| `lifecycle.v1` | Create/start/stop/restart/exec/attach/kill/pause/wait controls, persisted exit state, and process metadata |
| `inbound-unix-socket.v1` | Canonical guest socket intent, authority-selected host socket resolution, stable relay identity, and Docker-compatible guest ownership and mode; this transport primitive does not constitute a durable Engine API grant |
| `logging-drivers.v1` | Typed logging requests, durable native histories, remote/provider lifecycle, cache/read policy, and exact-process foreground attachment |
| `network-scoped-aliases.v1` | Source-scoped dynamic DNS aliases used to preserve Compose link isolation and target address changes |
| `observation.v1` | Container discovery, health, logs, events, statistics, top, and network/port observation |

The manifest declares code-level support in the matched build and its pinned
stack. It does not claim that the service is running or that host resources
such as virtualisation, networking, or GPU support are available. Compose
checks service readiness separately after capability negotiation, and each
command still reports runtime or host availability errors from its actual
operation.

## Change Procedure

1. Add or revise the typed capability in `ContainerVersion` with focused
   encoding and CLI-version tests.
2. Update the Compose typed requirement and
   `Tools/release/runtime-capabilities.json` together.
3. Update the exact Container and Containerization pins.
4. Run the stack consistency gate, focused stock-Apple and matched-runtime
   preflight tests, full repository CI, and the live release gate.
5. Record the capability's upstream disposition and remove it only after an
   Apple-native equivalent is merged, consumed, and parity-tested.

## Logging Capability

`io.github.stephenlclarke.container.logging-drivers.v1` requires the typed
logging create request, authority-owned protected options, native and remote
provider lifecycle, canonical reads, dual cache, and exact-process foreground
attachment in the
[Docker logging-driver design](docker-logging-driver-semantics-design.md).
It is present in the coordinated release manifest and shipped by
[`container-compose` 0.14.1](https://github.com/stephenlclarke/container-compose/releases/tag/0.14.1).
The immutable release manifest uses Container
`ecf6da9fd029a52717a574c4aab3ed5257bbeea2`, Engine API
`386a40c726ecd25d67a3e5933582aebbfbe4fa2f`, Containerization
`818f5917819a32dac1bc233605c253b4a105e0e0`, and SwiftNIO SSL
`09c5c9adcdd2a459187e45fe0143eb01063f244a`. The hosted Stable Release Gate
passed for this graph. Compose preflight still negotiates the identifier before
using advanced logging; advertising the requirement does not make every remote
provider universally available or close the remaining external-client,
failure, migration, security, and comparable-performance evidence.

Earlier signed logging checkpoints include Container
`ac77f7a38819c4f96581220bb58d89107b51826a` with Engine API
`9008251c444af483a60ff95efa4a9d745a444ed5` and
`fe4094d0d7a2372ad586d177aea3f9b0e299ebcb`, plus devcontainer
`63d2b4a122dfa0eb187ae82e48d14dc21b73c79e`. It adds typed public Docker
create/start/stop/delete, durable stopped-state projection, protected-effect
reconciliation, provider-root-scoped trust, and a protected read-only plugin
root. The isolated MBP certificate passes two native lifecycle cycles and one
public REST lifecycle with exact readable history; the focused plugin suite
passes 10/10 under warnings-as-errors.

Signed Engine API `da59cff5b11ba4049f631c886ac3b09b0c3108d6` and
Container `16a3419ae31bb5c18a934571c69348767a89233e` remove the former fixed
4096-store/32 GiB aggregate history ceiling while retaining the 8 MiB
per-store bound and a separate defensive on-disk directory scan bound. Focused
MBP proofs encode, decode, and publish 4097 stores exactly. Signed Engine API
`331ae39219b7c09a87f56acc9d7016c234afa06d` adds a compatible framed v2
format with 4 MiB independently authenticated windows, bounded file
publication, and destination file opening. Signed Container
`62455f657e8d22233736eec7c2438ca7a14553ce` adopts v2 for its native source
and destination while retaining v1 opening. Engine API
`44010b991cc5015e59ff81d2fa9917ae879d39d8` and
`0d008475bfb711f7b295e44342b98d1535ab3f12`, devcontainer
`b428031e4f1cc1bf2ede37a2b658962309e6e4c7`, and Container
`8683e35e93c345fe823c94dfea396ae268cd3556` plus
`60b5d5c1482a0f7edad03c72f4777f0d5fb6635f` complete record/file-backed
portable and native acquisition, canonical open, destination decode, staging,
promotion, and immutable publication. History is copied in 64 KiB chunks and
at most one bounded segment is mapped during validation; aggregate payload
history is no longer materialized.

Compose config and hashing never require a runtime lookup. Runtime preflight
retains optional and unknown installed identifiers separately from the mandatory
manifest, and passes the immutable selection into runtime execution options only
after stack compatibility and service readiness succeed. Commands that need
advanced logging on the preserved development stack require this exact
identifier before execution. Catalogue
discovery is diagnostic and never replaces authoritative create/start
validation. AWS Logs and Google Cloud Logs are present on the matched Container
head. The local journald provider contract, exact-generation shared-sandbox
service transport, bounded reconnect-safe client/server wire, restart-safe
writer/reader state, verified Linux/arm64 AF_VSOCK workload, concrete systemd
append/query adapter, protected materialisation, exact routing, readiness
withdrawal, generation rollover, and terminal reclamation are implemented.
Journald remains present in side-effect-free advertised discovery, while
concrete create/start resolution admits it only when the authority-owned
service passes its readiness contract. This prevents Docker `/info` from
materialising the journald sandbox. The signed local Container package installs
and supervises Engine API 0.3.5 at `/tmp/container-engine-<uid>/docker.sock`;
isolated `/_ping`, Docker CLI unversioned and `/v1.53/info`, and ordered cleanup
pass. The isolated Docker-plugin service verifies a closed
digest-pinned installation, runs the plugin beside its authenticated lifecycle
service in a read-only bounded shared-sandbox workload, persists replay-safe
writer and reader claims, and exposes direct `ReadLogs` only after the exact
generation is ready. Dynamic driver discovery therefore advertises an installed
plugin only after manifest, asset, generation, and readiness checks succeed.
Signed local Container `70f976611bd5e39a9bfeb4965df7c073bbd789ad`
permits distinct generations of one provider, persists immutable
staged/active/draining state, publishes one active generation, retains exact
draining-generation routing, rolls back failed/unhealthy activation, and
recovers after restart without provider lifecycle effects. Later signed heads
complete reference-aware quiescence, durable configuration/history migration,
terminal proof before alias cutover, final N reclamation, and distributable
plugin certification. Release trust and coordinated dependency publication
originally shipped in 0.11.0 and remain part of 0.14.1; complete paired Docker
provider certification and programme-level failure, migration, security, and
performance evidence remain.
