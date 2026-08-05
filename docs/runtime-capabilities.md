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
It is deliberately absent from the required release manifest because it is an
optional capability negotiated only for services that request advanced logging.
Published `origin/main` remains at reproducible Compose checkpoint
`1f0f944b3d918a39ad97d1f12bb7b7c5ef6146a0` and published Container baseline
`6c3f7d3701cf9400855849fa0e29dd75d7b9c45d`, which does not expose this
contract. Signed local Compose `main` through
`9479e0aaba2bca3402d30fb7b77e21478e0455bd` has the complete negotiation,
typed projection, and reconciled public-gateway evidence active. Its manifest
still names unpublished Container
checkpoint `2a79b4553a342e33411666a88ad20ccd2ce46551`; validation used the later
signed local Container implementation
`70f976611bd5e39a9bfeb4965df7c073bbd789ad`, signed handoff
`25eced9d673fde4104e8276456fc3e7b2709b0a2`, and matched local
Containerization head `864455bf1a104f0215b7c912a45800b0a0538973`. The matched
scoped package suite passes 1,861 Swift Testing tests plus 94 XCTest tests, and
the staged-generation gate passes 35 focused registry/provider/discovery/
authority tests. macOS Go race/vet passes at 70.2% statement coverage; the
preceding Linux/arm64 plugin-service race gate remains green at 74.1%. The public
`77f06d4c44341e04241941072fb69e2b85a6f5c1` Containerization pin cannot compile
the existing branch because it lacks the required sandbox/workload/network
APIs. This local source must not be pushed until hosted builds can fetch a
coordinated matched Container revision.

The latest signed local checkpoint is Container
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
MBP proofs encode, decode, and publish 4097 stores exactly. The remaining
large-history gap is bounded-memory, file-backed streaming across source
export, sealing, transfer decode, and destination staging; the current v1
package still materializes complete histories in memory.

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
plugin certification. Release trust, coordinated dependency publication, and
paired Docker certification remain.
