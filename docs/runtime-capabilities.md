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
It is present in the required manifest because the matched Container authority
now implements lossless requested/resolved state, defaults, distinct built-in
drivers, delivery/cache/read semantics, generation-fenced provider lifecycle,
and independent foreground attachment. The identifier describes that typed
authority contract; individual provider availability remains discoverable and
validated separately.

Compose config and hashing never require a runtime lookup. Runtime preflight
retains optional and unknown installed identifiers separately from the mandatory
manifest, and passes the immutable selection into runtime execution options only
after stack compatibility and service readiness succeed. Commands that need
advanced logging require this exact identifier before execution. Catalogue
discovery is diagnostic and never replaces authoritative create/start
validation; a request for AWS Logs, Google Cloud, journald, or the production
plugin plane still fails until its provider slice is implemented.
