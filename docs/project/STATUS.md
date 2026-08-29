# Status

This document describes the functionality available in the current stable
Container Compose release. It is written for people deciding what they can use
today.

Future parity work belongs in [BACKLOG.md](BACKLOG.md) and the live GitHub
hierarchy rooted at [issue #266](https://github.com/stephenlclarke/container-compose/issues/266).
Build and release policy remains in [BUILD.md](../guides/BUILD.md), while installation
guidance remains in [INSTALL.md](../guides/INSTALL.md).

## Current Stable Release

[`0.14.0`](https://github.com/stephenlclarke/container-compose/releases/tag/0.14.0)
was published for macOS arm64 on 29 August 2026.

The immutable release manifest selects:

- Container `ba9566840b087ac6d61ebb8be52b90ca03ba07cc`.
- Containerization `e5a92e86bf03eb2cc244b3b47b0413b3935abfe4`.
- Container builder shim `db3e99cc3d19b9a328eb51be3a023a178f80ee81`.
- Builder image digest
  `sha256:d81d12e1dca1133ede535483a809803e6b256555a73d17f207003279539454a4`.
- SwiftNIO SSL `09c5c9adcdd2a459187e45fe0143eb01063f244a`.

The hosted stable-release gate passed for that immutable package. Current and
Homebrew release artifacts are Developer ID signed, checksummed, attested, and
bound to the matched runtime stack.

## At a Glance

The current help surface contains 40 green commands, 6 partial commands, and 0
unsupported commands. It contains 262 green documented long options, 1 partial
long option, and 0 unsupported long options.

The six partial commands are `attach`, `events`, `exec`, `logs`, `run`, and
`up`. These commands already provide substantial working behavior. Their orange
markers identify deeper runtime or release-proof boundaries described below.

The only partial long option is `exec --privileged`. It grants Linux
capabilities, but the runtime does not yet provide Docker-complete privileged
device, cgroup, profile, and isolation behavior.

## Supported Runtime Lane

Container Compose is supported with the matched `stephenlclarke` Container,
Containerization, builder-shim, Engine API, and SwiftNIO SSL stack selected by
the release manifest.

Runtime-backed commands preflight the installed stack and service readiness
before loading the project or causing build and create side effects. A stock
Apple or mismatched Homebrew installation fails early with installation
guidance instead of continuing with an incompatible API graph.

ComposeCore remains runtime neutral. It imports no Apple package types and
communicates through `ComposeRuntimeSPI`. The Apple-backed provider owns OCI,
archive, DTO, and live-runtime translation.

Dedicated-VM isolation remains the default and gives each container a private
VM kernel. Users can select it explicitly with `container run --isolation
dedicated-vm` or Compose service `isolation: dedicated-vm`. Eligible built-in
Linux workloads can instead opt into `shared-vm`; they then share one Linux VM
kernel and security boundary while retaining private root filesystems and
workload lifecycle. Compose currently accepts shared isolation only with host,
none, or the built-in bridge network rather than Compose-created custom
networks.

## Project Loading and Configuration

Container Compose discovers the standard local Compose files and supports
explicit or repeated `--file`, `COMPOSE_FILE`, project directories, project
names, profiles, `.env`, `--env-file`, `COMPOSE_ENV_FILES`, interpolation, path
controls, and stdin.

Git project resources support Docker's `URL#ref:subdir` form. Relative env and
build paths resolve from the checkout, and Git resources work with top-level
files, `include`, and `extends.file`.

`oci://` project artifacts support Compose project manifests, Compose-file and
env-file layers, OCI 1.0 fallback manifests, OCI 1.1 artifact manifests, image
digest override layers, and image-index wrappers.

`config` and `convert` expose the implemented normalized model, hashes,
profiles, images, services, networks, volumes, models, environment and output
formats. YAML anchors, fragments, `x-*` extensions, interpolation, multi-file
merge behavior, local and Git-backed includes, and extends handling come from
`compose-go`.

## Compose File Functionality

Top-level `name` participates in normal project-name precedence. Legacy
`version` is accepted without driving runtime behavior.

Services support the current Compose Specification model, including image and
build selection, commands and entrypoints, environment, health checks,
dependencies, profiles, scaling, restart metadata, lifecycle hooks, configs,
secrets, networks, volumes, resources, labels, annotations, ports, develop
watch rules, and provider-service variable injection.

Top-level configs support file, environment, inline content, and external
resources. Top-level secrets support file, environment, and external resources.
External configs use the Compose-owned filesystem backend. External secrets use
the caller's macOS Keychain backend.

Provider services receive the normalized project environment and can inject
prefixed or exact-name variables into dependent services. Model definitions and
service model bindings are parsed and rendered. A model-runner backend is not
part of the current release, so model startup and endpoint injection remain
unavailable.

The Develop Specification supports `rebuild`, `restart`, `sync`,
`sync+restart`, and `sync+exec` actions. Rules support path, target, ignore,
include, initial synchronization, exec metadata, pruning, `watch --no-up`,
`up --watch`, and menu-driven watch operation.

Local Deploy behavior supports replicas, labels, endpoint mode, ordinary CPU,
memory and PID limits, memory reservation, GPU reservation metadata, and local
restart behavior. Replicated and global job modes use the same local
convergence, readiness, and restart behavior as ordinary services.

## Build and Image Functionality

The local Build Specification supports Dockerfiles, inline Dockerfiles,
contexts, additional local, image, Git, URL and `service:` contexts, build
arguments, targets, cache controls, platforms, labels, tags, SSH forwarding,
network selection, privileged build requests, provenance, SBOM, pull, push, and
dependency-aware build ordering.

Build secrets support files, environment values, and external Keychain-backed
values. Invocation-private files are removed after the build. Docker Compose
local behavior for secret `uid`, `gid`, and `mode` remains unchanged.

The matched builder verifies and caches file-synchronization inputs. Repeated
builds skip uploading an unchanged context while changed or unavailable inputs
still fail closed instead of reusing an unverified result.

`pull`, `push`, `images`, and image discovery use the matched runtime image
catalog. `publish` pushes service images and writes OCI project artifacts,
digest override layers, and optional application image indexes after the
Docker-compatible project safety preflights.

`commit` exports stopped or running service containers to OCI images and
preserves inherited image configuration, Compose health overrides, and volume
declarations. The default path briefly freezes a running root filesystem;
`--pause=false` uses the runtime's best-effort APFS copy-on-write snapshot.

## Service Lifecycle and Orchestration

Create, pull, build, start, stop, kill, pause, unpause, restart, remove, scale,
wait, down, and orphan handling are implemented. Dependency-sensitive work
remains ordered while independent pull, push, build, and lifecycle operations
can run in parallel under the configured limit.

Distinct Container VM boots can progress concurrently. The expensive
Virtualization.framework bootstrap phase uses bounded FIFO admission so large
projects do not overload the host. Eligible never-started dedicated containers
prewarm asynchronously after their durable create completes; init still starts
only on an explicit start or attach, and a failed or unreachable prewarm is
discarded so the foreground operation can retry cold. SSH-agent forwarding and
custom runtime handlers retain cold foreground bootstrap.

`up` supports build and pull policy, recreate controls, scaling, selected
attachment, dependency attachment, health-aware wait, wait timeout, exit-code
selection, menu and watch operation, anonymous-volume renewal, orphan removal,
and service-level `pre_start` helpers.

`run` supports one-off containers, service ports, explicit published ports,
volumes, environment, labels, entrypoint, user, working directory, aliases,
interactive operation, detach, remove-on-exit, signal propagation, detach keys,
cleanup, and exact exit status.

`ps` distinguishes Docker `created` and `exited` states. It supports service and
status filters, quiet, JSON, tables, structured field references, labels,
nested and root paths, variables, deterministic ranges, Go-template control
actions, whitespace trimming, and Docker row-formatting functions.

`stats` and `volumes` use the same structured formatting system. `top` returns
Docker-shaped process information through the runtime metadata API.

## Networking

The runtime supplies project networks, network-scoped container and service
DNS, aliases, scaled address sets, legacy and external links, attachment
lifecycle, published ports, `extra_hosts`, interface names, priorities, MTU,
and built-in bridge, host, and none modes.

The requested network model preserves driver options, IPAM driver and options,
ordered IPv4 and IPv6 pools, ranges, gateways, auxiliary addresses, and
explicit family flags through `config` and `convert`.

The live vmnet backend supports one IPv4 subnet with optional gateway,
allocation range and auxiliary reservations. It supports one IPv6 subnet with
an optional gateway, IPv6-only networks, automatic IPv6 prefixes, explicit
IPv6 disablement, static endpoint allocation, restart retention, and project
network cleanup.

Custom drivers, custom IPAM providers, multiple same-family pools, IPv6
allocation ranges and joined network namespaces are not current functionality.
They are tracked in [BACKLOG.md](BACKLOG.md#advanced-networking-and-ipam).

## Volumes, Mounts, Configs, and Secrets

The current runtime supports local ext4 named and anonymous volumes, bind
mounts, tmpfs and image masks, Dockerfile `VOLUME` discovery, deterministic
anonymous volumes, image-subtree copy-up, `volume.nocopy`, subpath validation,
volume retention, `down --volumes`, `rm --volumes`, and anonymous-volume
renewal. Tmpfs mount sources are preserved through runtime projection, and
ext4 recovery locates configured external journals before mounting a volume.

Local volume `size` and `journal` options have runtime behavior. Arbitrary
driver names and options can be represented, but they do not provide non-local
storage. Provider-backed shareable storage and advanced live mount propagation
are not current functionality.

`cp` supports host-to-service, service-to-host, service-to-service, stdin tar,
stdout tar, archive, follow-link, replica index, one-off containers, trailing
`/.`, and `--all`. The runtime streams archives and preserves content,
ownership, modes, timestamps, symbolic and hard links, sparse allocation, long
paths, and large files.

## Logging and Terminal Sessions

The release supplies durable `json-file` and `local` histories, `none`, Syslog,
Journald, Fluentd, GELF, Splunk HEC, AWS Logs, Google Cloud Logs, installed
Docker logging plugins, dual cache, bounded readers, recovery, rotation,
compression, and provider-root trust isolation.

`logs` supports follow, timestamps, prefixes, colors, replica indexes, tails,
time filters, restart retention, and scaled aggregation. Static Compose history
for `logging.driver: none` is successfully empty, matching Docker Compose.
Direct runtime readers and followed history still report an unsupported reader
when the selected driver has no read path.

Foreground `up` and `run` attach to the exact process before start. This avoids
depending on historical logging and preserves early output for readable,
unreadable, and `none` drivers.

Interactive terminal sessions support pre-start attachment, WebSocket attach,
TTY resize, Docker-compatible detach keys, detach without stopping, reattach,
signal forwarding, client-disconnect isolation, terminal exit, and cleanup.
Exec joins the selected container IPC namespace, including the shared-sandbox
lane, instead of leaking the runtime service namespace.

Complete Testcontainers and devcontainer certification, the remaining provider
failure and migration matrix, and comparable release performance are still
open parity work.

## Resources and Security

Current local controls include fractional and integral CPU limits, CPU period
and quota, CPU sets, CPU shares, hard memory limits, memory reservation, memory
swap, PID limits, shared-memory size, capabilities, selected sysctls,
`cgroup_parent`, and supported no-new-privileges and unconfined profile forms.

Running dedicated-VM containers accept live hard-memory target changes without
restart. An opt-in controller samples memory usage, lowers the target after
sustained low usage within its configured floor, and restores the boot-time
maximum under sustained pressure. Inspection and statistics continue to report
the effective runtime state.

Host and private cgroup, PID, IPC, UTS, and user namespace selections are
projected where the selected sandbox can represent them. The experimental
shared-VM mode does not yet provide Docker-compatible service or container PID,
IPC, or network namespace joins; those remain part of the multi-workload
namespace contract.

Realtime CPU, swappiness, OOM-kill disable, arbitrary user ID maps, complete
security profiles, rootfs storage options, generic devices, CDI, and
Docker-complete privileged behavior are not current functionality.

## Docker-Compatible Engine API

Released `container-engine-api` 0.3.5 owns the neutral wire types, a generated
API 1.44 through 1.53 operation ledger, hardened Unix listener, shared
`container-engine` executable, selected-provider fingerprinting, private
provider sessions, ping, WebSocket transport, and fail-closed response
composition.

The matched runtime implements system version, info, container and image
discovery, logs, lifecycle, TTY attach and resize, unauthenticated image pull,
tag and delete, and volume creation through the native authority. Focused
unmodified Docker CLI certificates cover these paths.

The matched runtime now also provides the typed inbound Unix-socket transport:
canonical guest intent, authority-selected host socket resolution, stable relay
identity, and Docker-oracled guest ownership and mode. This is a lower transport
primitive, not the complete Engine API socket grant.

Registry credentials, push, search, history, build and session transports,
most remaining generated routes, durable generation-fenced socket grant
records and recovery, complete Testcontainers and devcontainer adoption, and
`use_api_socket` are not current functionality.

## CLI Commands

The following 40 commands are green in the current help surface:

- `alpha`, `alpha dry-run`, `alpha scale`, and `alpha watch`.
- `bridge`, `bridge convert`, and `bridge transformations`.
- `bridge transformations create`, `bridge transformations list`, and
  `bridge transformations ls`.
- `build`, `commit`, `config`, `convert`, `cp`, `create`, and `down`.
- `export`, `help`, `images`, `kill`, `ls`, `pause`, `port`, and `ps`.
- `publish`, `pull`, `push`, `restart`, `rm`, `scale`, and `start`.
- `stats`, `stop`, `top`, `unpause`, `version`, `volumes`, `wait`, and `watch`.

### `attach`

Interactive init-process and output-only attachment, indexes, signal proxying,
detach keys, no-stdin operation, resize, detach, reattach, exit, and cleanup
work. The command remains orange until the complete external-client, provider,
failure, migration, security, and release-performance evidence is complete.

### `events`

Text and JSON output plus time filters work. Current actions include create,
start, pause, unpause, stop, delete, health, kill, die, destroy, and exec create,
start, and die. OOM, explicit restart, rename, resize, update, and attach/detach
actions remain parity work.

### `exec`

Indexes, environment, user, working directory, TTY, detach, and ordinary
service execution work. `--privileged` currently grants capabilities only and
does not provide Docker-complete privileged isolation or devices.

### `logs`

Follow, timestamps, prefixes, colors, indexes, tails, time filters, restart
retention, scaled aggregation, and supported histories work. The command remains
orange for the incomplete external-client, provider, migration, failure,
security, and performance matrices.

### `run`

One-off, foreground, interactive, detached, aliased, signalled, removable, and
exit-status paths work. The command remains orange because its foreground and
history behavior shares the remaining logging and external-client proof.

### `up`

Creation, startup, build, pull, recreate, scaling, dependency order, foreground
attachment, watch, menu, health wait, exit-code selection, pre-start helpers,
and service discovery work. The remaining orange marker covers the same
cross-client, provider, failure, migration, security, and performance proof as
the logging contract.

## CLI Options

`container compose --help` and `container compose COMMAND --help` are the
authoritative option reference.

All 262 documented long options are parsed and mapped for their current command
behavior except `exec --privileged`, whose partial behavior is described above.
Command parity remains a separate axis: a green flag does not override a deeper
runtime boundary described by its command.

## Current Validation

Normal repository validation uses `make ci`, targeted tests while iterating,
the complete Docker Compose parity target when Compose or runtime behavior
changes, and `make release-gate` before stable publication.

The 0.14.0 immutable package passed the hosted Stable Release Gate, including
the supported parity suite. Its exact release commit also completed CI,
Quality, CodeQL, Documentation, and Prebuilt Binaries successfully.

The maintained local parity suite covers project loading, Compose and
Dockerfile models, lifecycle, logging, terminal sessions, networking, IPAM,
volumes, archive copying, image behavior, formatting, and Docker-compatible
public API paths.

## Performance Evidence

Functional validation and comparable performance are separate claims. A slower
completed oracle can prove behavior, but it does not satisfy the performance
goal.

The latest uninterrupted 62-target same-host diagnostic completed on 30 July
2026. Its three-sample bridge startup median was 0.153 seconds for Docker
Compose and 1.228 seconds for Container Compose. Bridge teardown measured
10.178 seconds and 5.916 seconds respectively.

Later debug lifecycle diagnostics recorded larger startup and teardown ratios
at 10 and 50 services. Archive operations also retained material slowdowns.
These measurements identify optimization work; they are not release-artifact
evidence and must not be presented as a passing comparable-performance result.

The exact historical timings, revisions, fingerprints, and interpretation are
retained in the [macOS Compose parity and performance
review](../reviews/MACOS-COMPOSE-PARITY-AND-PERFORMANCE-REVIEW-2026-07-30.md).
The remaining release-performance contract is tracked by
[issue #278](https://github.com/stephenlclarke/container-compose/issues/278).

## Platform Boundaries

Windows-only settings and Docker Swarm scheduling are not local macOS Compose
functionality. They remain documented as platform or orchestration boundaries
rather than being silently counted as supported.

The enhanced matched runtime is the supported lane. Stock Apple convergence is
tracked separately in [issue #280](https://github.com/stephenlclarke/container-compose/issues/280)
and does not retract functionality available in the current release.

<a id="what-prevents-100-parity"></a>

## Future Work

Current functionality is described above. The complete parity roadmap,
cross-repository ownership, issue prefixes, and 1.0 release contracts are in
[BACKLOG.md](BACKLOG.md).
