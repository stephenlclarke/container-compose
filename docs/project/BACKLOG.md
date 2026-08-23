# Container Compose Backlog

This document explains the remaining Docker Compose parity work in human terms.
The authoritative, live backlog is the native GitHub issue hierarchy rooted at
[[Parity] Container Compose 1.0.0 completion](https://github.com/stephenlclarke/container-compose/issues/266).

[STATUS.md](STATUS.md) describes what the current stable release does today.
It deliberately does not own future work, maintain completion checklists, or
repeat issue state.

## How Work Is Classified

Every open issue in the Container Compose programme starts with a visible work
type.

- `[Parity]` identifies planned Docker Compose compatibility work.
- `[Bug]` identifies behavior that is already expected to work but does not.
- `[Release]` identifies certification, packaging, or publication work.
- `[Convergence]` identifies non-blocking adoption of stock Apple APIs.
- `[Request]` identifies an enhancement that is not yet accepted parity work.

A bug can block a parity contract, but it keeps the `[Bug]` prefix. GitHub's
parent relationship supplies the programme context without hiding whether the
work was planned or arose unexpectedly.

The same classification is available through `type:*` labels. Blocking 1.0
work also carries the `release: 1.0.0` label.

## How Cross-Repository Work Is Tracked

Product-visible contracts live in `container-compose`. Each contract has native
GitHub sub-issues in the repository that owns the implementation.

GitHub supports sub-issues from another repository when both repositories have
the same owner. This lets one Compose contract contain Container,
Containerization, Engine API, and devcontainer implementation children without
duplicating the source of truth.

A repository child closes after its implementation, focused tests, review, and
exact evidence merge. The parent contract closes only after every required
child and the end-to-end Docker or Compose oracle are complete. The 1.0 root
closes only after every blocking contract and the final release proof close.

Milestones are repository-local, so the `container-compose` 1.0 milestone is a
release view rather than the cross-repository relationship mechanism. Native
sub-issues and the shared labels provide the cross-repository view.

## 1.0 Completion Contract

Container Compose 1.0.0 keeps the project's existing goal: every
macOS-exercisable Docker Compose behavior must be green or explicitly
classified as a platform non-goal, and representative same-host performance
must be comparable to or better than Docker outside the declared noise band.

The following contracts block that release.

## Shared Namespaces and Privileged Isolation

Tracking issue: [[Parity] Shared namespaces and Docker-complete privileged
isolation](https://github.com/stephenlclarke/container-compose/issues/267).

The current one-VM-per-container runtime cannot provide Docker-compatible PID,
IPC, or network namespace joins while retaining private workload isolation.
`exec --privileged` grants capabilities, but the stack does not yet provide the
complete device, cgroup, profile, and isolation behavior expected from Docker
privileged containers.

The work introduces a durable multi-workload Linux sandbox, per-workload
namespaces and resource lifecycle, donor resolution and leases, DeviceBroker
and security policy, typed Compose and Engine contracts, coherent devcontainer
handoff, migration, recovery, and Docker oracles.

The detailed architecture is in the [shared namespace and privileged isolation
design](../architecture/shared-namespaces-privileged-isolation-design.md).

## Advanced Networking and IPAM

Tracking issue: [[Parity] Advanced networking and
IPAM](https://github.com/stephenlclarke/container-compose/issues/268).

The stable release preserves the complete requested IPAM model and proves one
IPv6-only network, one IPv4 allocation range with gateway and auxiliary
reservations, and a durable static endpoint. It also supplies network-scoped
service discovery, aliases, links, bridge, host, and none modes.

Remaining work covers custom network and IPAM providers, multiple same-family
pools, IPv6 allocation ranges and auxiliary addresses, durable provider and
controller reconciliation, joined network namespaces, supported reference data
planes, recovery, and release performance.

The implementation boundary is in the [advanced network and IPAM
design](../architecture/advanced-network-ipam-design.md).

## Non-Local Volumes and Advanced Mounts

Tracking issue: [[Parity] Non-local volumes and advanced
mounts](https://github.com/stephenlclarke/container-compose/issues/269).

Local ext4 volumes, image-volume copy-up, bind mounts, configs, secrets, and
selected volume lifecycle operations work today. An unavailable arbitrary
driver must not silently become local storage.

Remaining work includes provider-backed shareable storage, complete named and
anonymous volume lifecycle, recursive bind and propagation behavior, typed
guest attachment publication, subpaths, block and NBD paths, copy-up across
providers, migration, fault recovery, cleanup, and performance.

The cross-stack plan is in the [storage, mounts, and API socket
design](../architecture/non-local-volumes-advanced-mounts-api-socket-design.md).

## Docker API Socket and Engine API

Tracking issue: [[Parity] Complete the Docker API socket and Engine API
surface](https://github.com/stephenlclarke/container-compose/issues/270).

The released neutral Engine service already provides one selected-provider
listener, API version negotiation, discovery, lifecycle, logs, attach,
WebSocket resize, selected image mutations, and volume creation.

Remaining work includes the unimplemented generated routes, registry
credentials, image push, search and history, build and session transports,
large streams, durable generation-fenced guest socket grant records and
recovery, explicit authority handoff, Testcontainers and devcontainer adoption,
root and non-root end-to-end proof, and the exact `use_api_socket`
transformation. The typed inbound Unix-socket transport primitive is complete;
it does not by itself satisfy the grant or `use_api_socket` contract.

`use_api_socket` remains disabled until the complete authority, credential,
grant, security, recovery, and external-client contracts are proved.

## Docker Logging Semantics

Tracking issue: [[Parity] Complete Docker logging-provider and history
semantics](https://github.com/stephenlclarke/container-compose/issues/271).

Version 0.11.0 ships durable `json-file` and `local` histories, `none`, Syslog,
Journald, Fluentd, GELF, Splunk HEC, AWS Logs, Google Cloud Logs, installed
Docker logging plugins, dual cache, bounded live readers, recovery, rotation,
compression, and exact-process foreground attachment.

Remaining work covers the positive-budget GELF retry path, Unix-socket create
validation, complete provider, failure, migration, recovery and security
matrices, full Testcontainers and devcontainer proof, cold resource
measurement, and comparable release performance.

The exact provider and handoff contracts are in the [logging driver semantics
design](../architecture/docker-logging-driver-semantics-design.md).

## Devices, CDI, and GPUs

Tracking issue: [[Parity] Devices, CDI and GPU
support](https://github.com/stephenlclarke/container-compose/issues/272).

The current runtime exposes one virtio GPU and DRM subset. The 1.0 contract
needs a general DeviceBroker, lossless device requests, CDI selectors,
capability and option matching, provider inventory, durable leases, multiple
devices, recovery, and requested-versus-effective inspection.

Only hardware-feasible providers will be advertised. Unavailable vendor GPUs
or passthrough devices must produce exact, evidenced unavailability rather than
metadata-only success.

## Resource and Security Controls

Tracking issue: [[Parity] Remaining resource and security
controls](https://github.com/stephenlclarke/container-compose/issues/273).

The current release supplies the common CPU, memory, PID, capability, sysctl,
and selected security controls documented in STATUS. It does not yet complete
realtime CPU, swappiness, OOM-kill control, arbitrary user-namespace maps,
cgroup policy, immutable security profiles, or rootfs storage options.

The remaining contract covers requested, effective, and discarded policy;
capability negotiation; live guest effects; ID maps; profile storage and
compilation; rootfs storage; migration; recovery; fault injection; security
review; cross-client inspection; and performance.

The normative work packages are in the [resource and security controls
design](../architecture/remaining-resource-security-controls-design.md).

## Lifecycle States and Actions

Tracking issue: [[Parity] Docker lifecycle states and
actions](https://github.com/stephenlclarke/container-compose/issues/274).

Create, start, pause, unpause, stop, kill, delete, health, die, destroy, and exec
events are available. Docker-compatible `dead`, `restarting`, and `removing`
states and the complete OOM, explicit restart, rename, resize, update,
attach/detach, wait, and recovery action ledger are not.

The target is one immutable identity, one mutable-name index, one canonical
state transaction and event journal, generation-fenced guest actions, exact
wait and auto-remove semantics, durable recovery, and one state/event sequence
for every client.

The complete transition model is in the [lifecycle states and actions
design](../architecture/docker-lifecycle-states-actions-design.md).

## Model Runner Services

Tracking issue: [[Parity] Model Runner
services](https://github.com/stephenlclarke/container-compose/issues/275).

Compose currently parses, validates, and renders model definitions and service
bindings. No selected backend yet pulls, starts, supervises, or exposes a model
endpoint.

The remaining work includes a neutral Model SPI, a pinned provider, a secure
OCI model store, credentials, leases, concurrency, endpoint and network
effects, environment injection, progress, cancellation, response-loss and
restart recovery, devcontainer handoff, a runnable small-model oracle, security
review, and performance.

The architecture is in the [Model Runner services
design](../architecture/model-runner-services-design.md).

## Local Deploy Reservations

Tracking issue: [[Parity] Complete Local Deploy reservations and DeviceBroker
projection](https://github.com/stephenlclarke/container-compose/issues/276).

Local CPU, memory, PID limits, memory reservation, GPU reservation metadata,
and ordinary local behavior for replicated and job modes are implemented.

Valid scheduler-only CPU and generic reservations still need to be preserved
or ignored rather than rejected. Every valid non-GPU device reservation must
reach DeviceBroker. Schema-invalid reservation PID and device or generic-limit
fields must continue to fail through compose-go.

The corrected local-versus-Swarm boundary is in the [Local Deploy device and
resource design](../architecture/local-deploy-device-resource-subset-design.md).

## External-Client Certification

Tracking issue: [[Parity] External-client certification across Docker CLI,
Testcontainers and
devcontainer](https://github.com/stephenlclarke/container-compose/issues/277).

Focused Docker CLI certificates exist for several released surfaces. The final
1.0 graph still needs complete unmodified Docker CLI, Testcontainers, and real
VS Code or devcontainer matrices across provider, failure, migration, recovery,
security, restart, and cleanup boundaries.

Every client must observe the same identity, authority, state, history, and
event stream from one immutable published dependency graph without local
overrides.

## Comparable-or-Better Performance

Tracking issue: [[Parity] Comparable-or-better same-host
performance](https://github.com/stephenlclarke/container-compose/issues/278).

Existing diagnostics prove many functional contracts but record material
startup, teardown, first-attach, network, archive, and provider overhead. They
are not a passing release-performance result.

The remaining work completes the release-artifact builder, counterbalanced
scheduler, cold CPU/RSS/I/O collectors, `develop.watch` sync and build-context
lanes. It then profiles and optimizes every material median or P95 regression
without weakening semantic, durability, isolation, cleanup, or output proof.

The release passes only when every required metric is comparable to or better
than same-host Docker outside its declared noise band.

## Stable 1.0 Release Proof

Tracking issue: [[Release] Certify and publish Container Compose
1.0.0](https://github.com/stephenlclarke/container-compose/issues/279).

This gate starts after functionality and 1.0 bugs close. It owns exact clean
heads, dependency resolution, local and hosted gates, review-to-clean
convergence, signed tags and archives, checksums, attestations, prebuilt assets,
documentation, Homebrew formulae, clean installation, upgrade, rollback, and
independent publication verification.

Release proof cannot absorb or waive an unfinished parity contract.

## Stock Apple Convergence

Tracking issue: [[Convergence] Adopt equivalent stock Apple APIs when
available](https://github.com/stephenlclarke/container-compose/issues/280).

The supported runtime lane uses the matched Stephen-owned fork stack. Adoption
of equivalent released Apple APIs is tracked through Container,
Containerization, and builder-shim child issues.

This lane is important for reducing fork delta, but it does not block a
truthful 1.0 release on the enhanced stack.

## Working With the Backlog

Start with the [1.0 root issue](https://github.com/stephenlclarke/container-compose/issues/266).
Open a contract to see its repository children and automatic progress. Use the
shared labels to search across repositories.

When newly observed behavior is wrong, file a `[Bug]` issue and attach it to the
affected parity or release parent. Do not rewrite it as planned parity work.

When a parity contract changes, update its GitHub issue and the relevant design
in the same review. Update STATUS only when the behavior of the current matched
stack has actually changed.
