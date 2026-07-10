# Status

This file is the current-state handoff for `container-compose`. Keep branch policy in [BRANCHES.md](BRANCHES.md), validation evidence in GitHub Actions and SonarQube, and Apple-facing handoff drafts under `docs/upstream/`.

## Current State

`main` is the current releasable integration branch and source of stable semantic tags. Land validated slices on `main`, then use `make release VERSION_SELECTOR=--+` to produce the next stable release and Homebrew tap update. Keep branch policy, `scripts/CONTAINER_STACK_RELEASE.sh`, and Homebrew details in [BRANCHES.md](BRANCHES.md); this file should only record the current handoff state.

## Current Integration Assumption

`container-compose` is supported as part of the fork-backed Stephen runtime bundle. Keep each package lane pinned to the matching `stephenlclarke/container`, `stephenlclarke/containerization`, and `container-builder-shim` surfaces until equivalent Apple upstream APIs are accepted and the plugin has been updated to those upstream surfaces.

The main drift risks are logs, events, restart policy, health, exit/completion metadata, networking identity, IPAM/DNS, process listing, dynamic ports, copy/archive behavior, build inputs, mounts, secrets/configs, blkio, sysctls, and runtime API shape changes.

Current reviewed package pins:

- `stephenlclarke/container`: `bb5bc7f2e7e1f9d522db54a07aec45f9516f8cdb`
- `stephenlclarke/containerization`: `fbc08e7037736137eb0ba87784351bf44d29cefe`
- `ghcr.io/stephenlclarke/container-builder-shim/builder`: `0.13.8` for linux/arm64, `sha256:09f5d7927191013773f6cbe82a2a27a5be53c90862c0f81de03defb61dff040f`

## Current Validation

Use this validation floor for release-facing slices:

- `container-compose`: `make check`, `make cli-smoke-built`, `make docker-compose-health-wait-parity`, targeted Swift help tests when the CLI support matrix changes, markdownlint for touched docs, and release asset/tap checksum verification during release.
- `container`: `make check`, `make test`, targeted lifecycle integration tests, and full `make integration` when runtime behavior changes.

Stable package workflows publish `container-compose-plugin-release-arm64.tar.gz`, verify the release asset checksum, and update the Homebrew tap after artifacts are ready. The source formula records the current stable release URL, version, and checksum.

## Parity Legend

- ✅ Yes: green tick; Docker Compose v2 parity is implemented for the current Stephen fork-backed runtime lane.
- ⚠️ Partial: orange exclamation; a Docker Compose-compatible subset is implemented and the details list the remaining gap.
- ❌ No: red cross; the surface is intentionally rejected before side effects or has no implementation.

Runtime-backed commands preflight the installed stack before work begins. Apple stock or mismatched Homebrew installs fail with [INSTALL.md](INSTALL.md) guidance instead of a late unsupported-feature or runtime error.

Surface names follow the current Docker Docs [Compose file reference](https://docs.docker.com/reference/compose-file/), [Services reference](https://docs.docker.com/reference/compose-file/services/), [Build Specification](https://docs.docker.com/reference/compose-file/build/), [Deploy Specification](https://docs.docker.com/reference/compose-file/deploy/), [Develop Specification](https://docs.docker.com/reference/compose-file/develop/), [Dockerfile reference](https://docs.docker.com/reference/dockerfile/), and [Compose CLI reference](https://docs.docker.com/reference/cli/docker/compose/). This file records current state only; it is not a release history.

## Compose Surface Matrix

| Surface | Parity | Details |
| --- | --- | --- |
| Compose project loading and normalization | ⚠️ Partial | `compose-go` handles local/default files, multiple files, profiles, interpolation, env files, service `env_file` short/long syntax, project name and directory selection, extension preservation, and `config` YAML/JSON output; the normalizer adds Docker Compose-compatible raw-format env-file parsing. Docker Compose remote `-f` sources such as `oci://` artifacts and Git repository URLs are not implemented. |
| CLI command surface | ⚠️ Partial | 43 commands are ✅, 1 is ⚠️, and 2 are ❌ across the current Docker Compose v2 command reference plus this plugin's explicit `help` command. See [CLI Command Surface](#cli-command-surface). |
| CLI option surface | ⚠️ Partial | 249 documented long options are ✅, 2 are ⚠️, and 12 are ❌ across the current Docker Compose v2 option reference. See [CLI Option Surface](#cli-option-surface). |
| Dockerfile and build inputs | ⚠️ Partial | Dockerfile instruction execution, contexts, `dockerfile`, `dockerfile_inline`, `.dockerignore`, args, additional contexts, cache hints, labels, target, platforms, pull/no-cache, tags, `extra_hosts`, BuildKit network, isolation, privileged build, shm size, ulimits, SSH forwarding, provenance, SBOM, builder selection, `--print`, and `--check` are implemented. Build secrets are limited to file/env-backed BuildKit secret IDs; unsupported secret shapes are rejected. |
| Image pull, push, and local image metadata | ✅ Yes | `pull`, `push`, `images`, image digest config output, pull policy, quiet modes, failure-ignore modes, and dependency image traversal are implemented. |
| Service lifecycle orchestration | ⚠️ Partial | `create`, health-aware `up` and `start` waits, `stop`, `restart`, `kill`, `pause`, `unpause`, `rm`, `down`, `scale`, `wait`, service `post_start`, and service `pre_stop` are implemented. Durable job-completion metadata and service `pre_start` remain runtime gaps. |
| Process execution and attach | ⚠️ Partial | `run` and `exec` are implemented, including env, user, workdir, entrypoint, labels, caps, ports, volumes, service ports, aliases, and privileged mode. `attach --no-stdin` is implemented; interactive stdin/stdout/stderr reattach and detach-key handling remain runtime gaps. |
| Logs, events, stats, top, and ps | ⚠️ Partial | `logs`, `events`, `stats`, `top`, `ps`, `ls`, and `port` are implemented. Logging drivers are limited to `json-file`, `local`, and `none`; log options are limited to `max-size` and `max-file`. |
| Ports and service discovery | ✅ Yes | Short and long published ports, dynamic port allocation, host address/protocol matching, `expose`, `port`, `links`, `external_links`, and single-network aliases are implemented. |
| Networks and IPAM | ⚠️ Partial | Project networks, `internal`, driver metadata, top-level `driver_opts`, one IPv4 subnet, one IPv6 subnet, host/no-network modes, service MTU driver option, and single-network MAC/alias attachment are implemented. IPAM driver/options/gateway/ranges/aux addresses, multiple subnets of one family, endpoint `ipv4_address`/`ipv6_address`/`link_local_ips`/`interface_name`/`gw_priority`/`priority`, arbitrary endpoint driver options, and multi-network aliases remain runtime gaps. |
| Volumes, mounts, configs, and secrets | ⚠️ Partial | Named, bind, anonymous, tmpfs, `volumes_from`, bind `create_host_path`, bind propagation, file/env-backed configs and secrets, and service mount labels are implemented. Mount `consistency`, SELinux, recursive bind, `volume.subpath`, image subpath, unsupported mount types, API socket handoff, and nested bind mount overlay behavior remain gaps. |
| Runtime resources and security options | ⚠️ Partial | `cpus`, `mem_limit`, `pids_limit`, blkio controls, `sysctls`, `ulimits`, `shm_size`, `privileged`, `cap_add`, `cap_drop`, `read_only`, `init`, restart policy, stop signal/grace period, hostname/domainname, DNS options, and extra hosts are implemented. Advanced CPU scheduler fields, memory reservation/swap/swappiness/OOM controls, cgroup fields, IPC, isolation, user namespace, UTS, supplemental groups, and `security_opt` remain runtime gaps. |
| Devices and GPU | ⚠️ Partial | `device_cgroup_rules` and Linux VM `devices` mappings are implemented through the fork-backed runtime. `gpus`, credential specs, arbitrary macOS hardware passthrough, and Deploy device reservations remain runtime gaps. |
| Namespace modes | ⚠️ Partial | `network_mode: none`, `network_mode: host`, and `pid: host` are implemented. `network_mode: service:NAME`, `network_mode: container:NAME`, `pid: service:NAME`, and `pid: container:NAME` need Docker-compatible namespace-join primitives. |
| Healthchecks and dependency conditions | ✅ Yes | Compose and Dockerfile healthchecks are projected into the fork-backed runtime, probes publish Docker-compatible state and transition events, `condition: service_healthy` gates dependents, `up/start --wait` wait for health, and `ps` reports current health. The runtime alignment is tracked against [apple/container#1918](https://github.com/apple/container/issues/1918). |
| Deploy specification | ⚠️ Partial | Replicas, local job modes, stop-first update delay, restart policy metadata, deploy labels, CPU/memory local limits, CPU/memory reservation metadata, and `endpoint_mode` metadata are implemented. Start-first updates, scheduler placement behavior, pids/device/generic reservations, pids/device/generic limits, and remaining Swarm scheduler semantics remain gaps. |
| Develop specification and watch | ✅ Yes | `develop.watch` supports `rebuild`, `restart`, `sync`, `sync+restart`, and `sync+exec`, including include/ignore filters, initial sync, prune, `watch --no-up`, `up --watch`, and `up --menu --watch`. |
| Provider and model services | ⚠️ Partial | Provider services run through the Compose provider protocol and inject provider variables into dependent services. Compose model bindings are rejected until a model-runner backend and endpoint injection primitive exist. |
| Labels, annotations, and metadata | ✅ Yes | Service labels, label files, annotations, container names, project/resource labels, deploy labels, top-level volumes/configs/secrets metadata, and Compose extension fields are preserved or mapped where Docker Compose local mode expects them. |

## Compose File Surface

The Docker Compose v2 file reference is a rolling Compose Specification surface: top-level project elements, services, networks, volumes, configs, secrets, optional Build/Deploy/Develop specifications, provider/model extensions, fragments, merge behavior, interpolation, profiles, and include behavior. The current parity state is:

| Compose File Surface | Parity | Details |
| --- | --- | --- |
| Project file discovery and sources | ⚠️ Partial | Default local file discovery, explicit local `--file`, repeated files, `COMPOSE_FILE`, `.env`, `--env-file`, project directory, project name, profiles, interpolation controls, path-resolution controls, and stdin-style local loader paths are handled by `compose-go`. Docker Compose remote `-f` sources such as `oci://` artifacts and Git repository URLs are not implemented. |
| Top-level `name` and legacy `version` | ✅ Yes | `name` participates in project naming precedence, and legacy `version` is accepted by the Compose Specification loader without driving behavior. |
| Top-level `services` | ⚠️ Partial | Service definitions are parsed and normalized across the current Docker Compose service attribute surface. Runtime-backed gaps are listed in [Service Attribute Surface](#service-attribute-surface), the current-state matrix, and the CLI tables. |
| Top-level `networks` | ⚠️ Partial | Project networks, explicit names, external names, `internal`, driver metadata, top-level `driver_opts`, and one IPv4 plus one IPv6 IPAM subnet are implemented. IPAM driver/options/gateway/ranges/aux addresses and multiple subnets of the same address family remain runtime gaps. |
| Top-level `volumes` | ✅ Yes | Named volumes, explicit names, external volumes, local driver metadata, driver options, labels, and project labels are implemented through the direct runtime API. |
| Top-level `configs` | ⚠️ Partial | File-backed and environment-backed configs are materialized as read-only service mounts with Compose metadata. External configs and non-file/non-env config backends remain runtime gaps. |
| Top-level `secrets` | ⚠️ Partial | File-backed and environment-backed secrets are materialized as read-only service mounts and build secrets. External secrets and non-file/non-env secret backends remain runtime gaps. |
| Extensions, fragments, merge, and include | ✅ Yes | YAML anchors/fragments, `x-*` extension fields, multi-file merge behavior, and Compose include handling are delegated to `compose-go`; extension data is preserved in normalized config output. |
| Compose Build Specification | ⚠️ Partial | See [Dockerfile And Build Surface](#dockerfile-and-build-surface) for every build attribute and Dockerfile-adjacent behavior. |
| Compose Deploy Specification | ⚠️ Partial | Replicas, local job modes, stop-first update delay, restart policy metadata, labels, CPU/memory local limits, CPU/memory reservation metadata, and `endpoint_mode` metadata are implemented. Start-first updates, scheduler placement behavior, pids/device/generic reservations, pids/device/generic limits, and Swarm scheduler behavior remain gaps. |
| Compose Develop Specification | ✅ Yes | `develop.watch` supports `rebuild`, `restart`, `sync`, `sync+restart`, and `sync+exec`, including include/ignore filters, initial sync, prune, `watch --no-up`, `up --watch`, and `up --menu --watch`. |
| Provider services and models | ⚠️ Partial | Provider services run through the Compose provider protocol and inject provider variables into dependents. Compose model bindings are rejected until a model-runner backend and endpoint injection primitive exist. |

## Service Attribute Surface

Docker Compose service attributes are grouped here by runtime behavior so every current service surface has a yes/no/partial indicator without turning this handoff into generated API documentation.

| Service Attribute Surface | Parity | Details |
| --- | --- | --- |
| Identity, image, process, and profile attributes | ✅ Yes | `image`, `platform`, `pull_policy`, `profiles`, `attach`, `container_name`, `hostname`, `domainname`, `command`, `entrypoint`, `working_dir`, `user`, `stdin_open`, `tty`, `init`, `runtime`, and `scale` are parsed and mapped into local orchestration. |
| Labels, annotations, and extension metadata | ✅ Yes | `labels`, `label_file`, `annotations`, service `x-*` extensions, container names, project labels, and service metadata are preserved or projected where Docker Compose local mode expects them. |
| Environment and env files | ✅ Yes | `environment` and `env_file` short/long syntax are implemented, including optional missing env files and `format: raw` values. Service env files are resolved during normalization like Docker Compose and are not forwarded as runtime `--env-file` arguments. |
| Build-backed services | ⚠️ Partial | `build` string syntax and detailed Build Specification attributes are implemented through the supported Dockerfile/build surface. Build-secret metadata and unsupported secret source shapes remain the only known Build Specification gaps. |
| Dependencies and links | ⚠️ Partial | `depends_on`, `links`, and `external_links` ordering/discovery are implemented, including `condition: service_healthy` and dependency restart/required metadata where local mode can honor it. Durable job-completion dependency metadata remains a runtime gap. |
| Ports and exposure | ✅ Yes | `ports` short/long syntax, dynamic host ports, ranges, host IPs, protocols, named/app-protocol metadata, `expose`, and `port` lookup are implemented for local mode. |
| Network attachments and discovery | ⚠️ Partial | `networks`, `network_mode: none`, `network_mode: host`, single-network `aliases`, service MTU `driver_opts`, `mac_address`, DNS fields, and `extra_hosts` are implemented where the runtime exposes matching primitives. Endpoint `ipv4_address`, `ipv6_address`, `link_local_ips`, `interface_name`, `gw_priority`, `priority`, arbitrary endpoint `driver_opts`, multi-network aliases, `network_mode: service:NAME`, and `network_mode: container:NAME` remain runtime gaps. |
| Volumes, mounts, configs, and secrets | ⚠️ Partial | `volumes`, `volumes_from`, `volume_driver`, `tmpfs`, `configs`, and `secrets` are implemented for named, bind, anonymous, tmpfs, file-backed, and env-backed local mode. Mount `consistency`, SELinux, recursive bind, `volume.subpath`, image subpath, `npipe`, `cluster`, API socket handoff, external config/secret backends, and non-file/non-env config/secret sources remain gaps. |
| Runtime resources and security | ⚠️ Partial | `cpus`, `pids_limit`, `blkio_config`, `sysctls`, `ulimits`, `shm_size`, `privileged`, `cap_add`, `cap_drop`, `read_only`, `restart`, `stop_signal`, and `stop_grace_period` are implemented. `cpu_count`, `cpu_percent`, `cpu_shares`, `cpu_period`, `cpu_quota`, `cpu_rt_runtime`, `cpu_rt_period`, `cpuset`, `mem_reservation`, `memswap_limit`, `mem_swappiness`, `oom_kill_disable`, `oom_score_adj`, `cgroup`, `cgroup_parent`, `ipc`, `isolation`, `group_add`, `security_opt`, `storage_opt`, `userns_mode`, and `uts` are parsed but remain fully or partly limited by runtime primitives. |
| Devices, GPU, and credentials | ⚠️ Partial | `devices` and `device_cgroup_rules` are implemented through the fork-backed runtime. `gpus`, `credential_spec`, and arbitrary macOS hardware passthrough remain runtime gaps. |
| Logging | ⚠️ Partial | `logging.driver` supports `json-file`, `local`, and `none`; `logging.options` supports `max-size` and `max-file`. Other logging drivers/options are rejected before side effects. |
| Healthchecks | ✅ Yes | `healthcheck` and Dockerfile `HEALTHCHECK` defaults/overrides are projected into typed runtime configuration. Probe cadence and state, `service_healthy`, health-aware `up/start --wait`, transition events, and `ps` health output are implemented. |
| Lifecycle hooks | ⚠️ Partial | `post_start` and `pre_stop` hooks run for detached and managed lifecycle paths with command/user/privileged/working-directory/environment metadata. Foreground attach paths still have explicit unsupported errors, and Docker Compose `pre_start` init containers are not implemented. |
| Deploy Specification attributes | ⚠️ Partial | `deploy.mode`, `replicas`, `labels`, `endpoint_mode`, `resources.limits`, CPU/memory `resources.reservations`, and restart policy metadata are implemented for local behavior or preserved as scheduler metadata. `placement`, `update_config` start-first behavior, `rollback_config`, pids/device/generic reservations, pids/device/generic limits, and Swarm scheduler semantics remain gaps. |
| Develop Specification attributes | ✅ Yes | `develop.watch` supports `rebuild`, `restart`, `sync`, `sync+restart`, and `sync+exec`, including `path`, `action`, `target`, `ignore`, `include`, `initial_sync`, and `exec` metadata. |
| Provider and model attributes | ⚠️ Partial | `provider` services run through the Compose provider protocol and inject provider variables into dependents. Service `models` and top-level `models` are parsed and rendered by `config`, but runtime model-runner startup and endpoint injection are rejected until a backend exists. |

## Dockerfile And Build Surface

| Dockerfile / Build Surface | Parity | Details |
| --- | --- | --- |
| Dockerfile instruction set and parser directives | ✅ Yes | Service builds run through the fork-backed `container build` BuildKit path, so Dockerfile parser directives and instruction parsing/execution follow the supported BuildKit backend. |
| `.dockerignore` context filtering | ✅ Yes | Build contexts use the fork-backed builder-shim filter path, including negation patterns that re-include descendants below excluded parent directories. |
| Build context string syntax | ✅ Yes | `build: ./dir` resolves to a context directory with the default `Dockerfile`, matching Docker Compose local mode. |
| `build.context` | ✅ Yes | Local relative and absolute contexts are resolved, and remote BuildKit references are passed through to the builder. |
| `build.dockerfile` | ✅ Yes | Alternate Dockerfile paths are resolved relative to the effective build context, including remote-context pass-through. |
| `build.dockerfile_inline` | ✅ Yes | Inline Dockerfiles are materialized for live builds and rendered as `dockerfile-inline` in `build --print` bake output. |
| `build.additional_contexts` | ✅ Yes | Local, image, Git/URL-style, and `service:NAME` contexts are mapped to BuildKit `--build-context` or bake contexts; service contexts are built in dependency order. |
| `build.args` and `build --build-arg` | ✅ Yes | Compose-file and CLI build arguments merge with Docker Compose-compatible environment lookup for key-only CLI args. |
| `build.cache_from` and `build.cache_to` | ✅ Yes | Cache hints are forwarded to live builds and bake output. |
| `build.entitlements` | ✅ Yes | Entitlements are forwarded as BuildKit `--allow` values. |
| `build.extra_hosts` | ✅ Yes | Build-time host entries are forwarded to the builder. |
| `build.isolation` | ✅ Yes | The field is accepted and preserved in normalized config; local Docker Compose omits it from Buildx bake output on this platform, and this plugin mirrors that behavior. |
| `build.labels` | ✅ Yes | Build labels are forwarded to live builds and bake output. |
| `build.network` | ✅ Yes | BuildKit network mode is forwarded to live builds and bake output. |
| `build.no_cache` and `--no-cache` | ✅ Yes | File and CLI no-cache controls are applied to live builds and bake output. |
| `build.platforms` | ✅ Yes | Target platforms are forwarded to live builds and bake output. |
| `build.privileged` | ✅ Yes | Privileged build mode is forwarded to the fork-backed builder. |
| `build.provenance` | ✅ Yes | Compose-file and CLI provenance attestations are forwarded, including Docker Compose-compatible false/disabled handling. |
| `build.pull` and `--pull` | ✅ Yes | File and CLI pull controls are applied to live builds and bake output. |
| `build.sbom` | ✅ Yes | Compose-file and CLI SBOM attestations are forwarded, including Docker Compose-compatible false/disabled handling. |
| `build.secrets` | ⚠️ Partial | File-backed and environment-backed BuildKit secret IDs are supported. Secret metadata such as uid/gid/mode is accepted by Compose local mode as metadata but is not projected into BuildKit secret entries; unsupported secret shapes are rejected before side effects. |
| `build.ssh` and `build --ssh` | ✅ Yes | Compose-file and CLI SSH forwarding entries are merged with Docker Compose-compatible CLI override behavior by SSH ID. |
| `build.shm_size` | ✅ Yes | Build shared-memory size is forwarded to the builder. |
| `build.tags` | ✅ Yes | Additional image tags are forwarded and de-duplicated with the service image tag. |
| `build.target` | ✅ Yes | Target stages are forwarded to live builds and bake output. |
| `build.ulimits` | ✅ Yes | Build ulimits are forwarded to the builder. |
| `build --builder` | ✅ Yes | Named fork-backed builders are selected for live builds; `build --print` omits builder selection from bake JSON like Docker Compose. |
| `build --check` | ✅ Yes | BuildKit lint/check mode runs without exporting an image; `build --print --check` emits bake `call: "lint"`. |
| `build --print` | ✅ Yes | Buildx bake JSON is rendered without build side effects and includes supported contexts, args, cache, labels, tags, target, platforms, pull/no-cache, secrets, SSH, attestations, outputs, and lint calls. |
| Dockerfile `HEALTHCHECK` inheritance | ✅ Yes | Dockerfile healthcheck metadata is inherited through the fork-backed image metadata API, explicit Compose overrides merge with image defaults, and the resulting probes drive dependency gating, health-aware waits, events, and status output. |

## CLI Command Surface

| Command | Parity | Details |
| --- | --- | --- |
| `alpha` | ✅ Yes | Experimental namespace help and the Docker-documented dry-run, scale, and watch aliases are implemented. |
| `alpha dry-run` | ✅ Yes | Experimental `alpha dry-run -- COMMAND` wraps the requested Compose command with root `--dry-run` while preserving project/global options. |
| `alpha scale` | ✅ Yes | Experimental `alpha scale` is implemented as an alias for the stable `scale` command. |
| `alpha watch` | ✅ Yes | Experimental `alpha watch` is implemented as an alias for the stable `watch` command. |
| `attach` | ⚠️ Partial | `--no-stdin` output-follow attach is implemented; default interactive reattach and detach-key handling need runtime support. |
| `bridge` | ✅ Yes | The complete Compose Bridge CLI runtime is implemented for the fork-backed runtime lane. |
| `bridge convert` | ✅ Yes | Models include image ports, published target ports, and text or binary config and secret content; Kubernetes, Helm, custom templates, repeated transformations, and empty-output current-directory mode run through local transformer images. |
| `bridge transformations` | ✅ Yes | Bridge transformation image management is implemented. |
| `bridge transformations create` | ✅ Yes | A stopped transformer rootfs is exported, only `/templates` is securely extracted, and a standard rebuildable Dockerfile is written. |
| `bridge transformations list` | ✅ Yes | Local transformer images labelled `com.docker.compose.bridge=transformation` are listed in Docker-shaped table, JSON, and quiet modes. |
| `bridge transformations ls` | ✅ Yes | Alias for `bridge transformations list`. |
| `build` | ✅ Yes | Dockerfile/build parity is implemented for the supported build surface above. |
| `commit` | ❌ No | Container commit/image mutation is not implemented. |
| `config` | ✅ Yes | Compose project rendering and config query options are implemented. |
| `convert` | ✅ Yes | Docker Compose's config-compatible model conversion projections are implemented for the documented local output modes. |
| `cp` | ✅ Yes | File copy in/out is implemented for non-streaming paths. |
| `create` | ✅ Yes | Service creation, build/pull/recreate controls, scaling, and orphan handling are implemented. |
| `down` | ✅ Yes | Container, network, image, volume, timeout, orphan, and service-scoped cleanup are implemented. |
| `events` | ✅ Yes | Event output, JSON mode, and time filters are implemented. |
| `exec` | ✅ Yes | Service exec options, indexes, env, user, workdir, tty, detach, and privileged mode are implemented. |
| `export` | ✅ Yes | Container filesystem export to an archive path is implemented. |
| `help` | ✅ Yes | Docker Compose-compatible help rendering and support colors are implemented. |
| `images` | ✅ Yes | Image listing and formatting are implemented. |
| `kill` | ✅ Yes | Signal and orphan handling are implemented. |
| `logs` | ✅ Yes | Follow, timestamps, prefix/color controls, indexes, tail, and time filters are implemented. |
| `ls` | ✅ Yes | Project listing, filters, formats, quiet, and all modes are implemented. |
| `pause` | ✅ Yes | Service pause is implemented. |
| `port` | ✅ Yes | Published-port lookup by service, index, and protocol is implemented. |
| `ps` | ✅ Yes | Container listing, filters, statuses, service selection, formats, and quiet/services output are implemented. |
| `publish` | ❌ No | Compose application publishing is not implemented. |
| `pull` | ✅ Yes | Pull policy, dependency inclusion, quiet mode, and ignore-failure behavior are implemented. |
| `push` | ✅ Yes | Dependency inclusion, quiet mode, and ignore-failure behavior are implemented. |
| `restart` | ✅ Yes | Service restart, dependency control, and timeout are implemented. |
| `rm` | ✅ Yes | Stopped-container removal, force, stop, and volume cleanup are implemented. |
| `run` | ✅ Yes | One-off containers and Docker Compose run options are implemented. |
| `scale` | ✅ Yes | Service scaling and dependency control are implemented. |
| `start` | ✅ Yes | Start, health-aware wait, and wait-timeout behavior are implemented. |
| `stats` | ✅ Yes | Table/JSON formatting, stopped-container inclusion, no-stream, and no-trunc modes are implemented. |
| `stop` | ✅ Yes | Stop and timeout are implemented. |
| `top` | ✅ Yes | Process listing is implemented. |
| `unpause` | ✅ Yes | Service unpause is implemented. |
| `up` | ✅ Yes | Create/start/attach/watch/menu/build/pull/recreate/exit-control/log-output/scaling behavior and health-aware `--wait`/`--wait-timeout` are implemented. |
| `version` | ✅ Yes | Pretty, short, and JSON version output are implemented. |
| `volumes` | ✅ Yes | Volume listing, quiet, and formatting are implemented. |
| `wait` | ✅ Yes | Container exit waiting and `--down-project` cleanup are implemented. |
| `watch` | ✅ Yes | Develop watch actions and options are implemented. |

## CLI Option Surface

`container compose --help` and `container compose COMMAND --help` are the authoritative usage views. Every documented long option surface is listed here with per-option parity markers.

| Option Surface | Parity | Details |
| --- | --- | --- |
| Root options | ⚠️ Partial | ✅ `--all-resources`: selected-service `config` and `convert` output keeps unreferenced top-level networks, volumes, configs, and secrets, ✅ `--ansi`, ✅ `--compatibility`: uses Docker Compose legacy underscore separators for generated service and one-off container names, ✅ `--dry-run`, ✅ `--env-file`, ✅ `--file`, ✅ `--profile`, ✅ `--progress`, ✅ `--project-directory`, ✅ `--project-name`, ✅ `--verbose`; ⚠️ `--parallel`: caps repeated `pull` and `push` image operations while dependency-sensitive orchestration stays ordered. |
| `alpha` options | ✅ Yes | ✅ `--dry-run`. |
| `alpha dry-run` options | ✅ Yes | ✅ `--dry-run`: accepted and implied for the wrapped command. |
| `alpha scale` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-deps`. |
| `alpha watch` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-up`, ✅ `--quiet`. |
| `attach` options | ⚠️ Partial | ✅ `--dry-run`, ✅ `--index`, ✅ `--no-stdin`, ✅ `--sig-proxy`; ⚠️ `--detach-keys`: parsed and documented, but output-only attach ignores detach keys because interactive reattach is not exposed by the runtime. |
| `bridge` options | ✅ Yes | ✅ `--dry-run`. |
| `bridge convert` options | ✅ Yes | ✅ `--dry-run`, ✅ `--output`, ✅ `--templates`, ✅ `--transformation`. |
| `bridge transformations` options | ✅ Yes | ✅ `--dry-run`. |
| `bridge transformations create` options | ✅ Yes | ✅ `--dry-run`, ✅ `--from`. |
| `bridge transformations list` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--quiet`. |
| `bridge transformations ls` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--quiet`. |
| `build` options | ✅ Yes | ✅ `--build-arg`, ✅ `--builder`, ✅ `--check`, ✅ `--dry-run`, ✅ `--memory`, ✅ `--no-cache`, ✅ `--print`, ✅ `--provenance`, ✅ `--pull`, ✅ `--push`, ✅ `--quiet`, ✅ `--sbom`, ✅ `--ssh`, ✅ `--with-dependencies`. |
| `commit` options | ❌ No | ❌ `--author`, ❌ `--change`, ❌ `--dry-run`, ❌ `--index`, ❌ `--message`, ❌ `--pause`: `commit` is not implemented. |
| `config` options | ✅ Yes | ✅ `--dry-run`, ✅ `--environment`, ✅ `--format`, ✅ `--hash`, ✅ `--images`, ✅ `--lock-image-digests`, ✅ `--models`, ✅ `--networks`, ✅ `--no-consistency`, ✅ `--no-env-resolution`, ✅ `--no-interpolate`, ✅ `--no-normalize`, ✅ `--no-path-resolution`, ✅ `--output`, ✅ `--profiles`, ✅ `--quiet`, ✅ `--resolve-image-digests`, ✅ `--services`, ✅ `--variables`, ✅ `--volumes`. |
| `convert` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--hash`, ✅ `--images`, ✅ `--no-consistency`, ✅ `--no-interpolate`, ✅ `--no-normalize`, ✅ `--output`, ✅ `--profiles`, ✅ `--quiet`, ✅ `--resolve-image-digests`, ✅ `--services`, ✅ `--volumes`. |
| `cp` options | ✅ Yes | ✅ `--all`, ✅ `--archive`, ✅ `--dry-run`, ✅ `--follow-link`, ✅ `--index`. |
| `create` options | ✅ Yes | ✅ `--build`, ✅ `--dry-run`, ✅ `--force-recreate`, ✅ `--no-build`, ✅ `--no-recreate`, ✅ `--pull`, ✅ `--quiet-pull`, ✅ `--remove-orphans`, ✅ `--scale`, ✅ `--yes`. |
| `down` options | ✅ Yes | ✅ `--dry-run`, ✅ `--remove-orphans`, ✅ `--rmi`, ✅ `--timeout`, ✅ `--volumes`. |
| `events` options | ✅ Yes | ✅ `--dry-run`, ✅ `--json`, ✅ `--since`, ✅ `--until`. |
| `exec` options | ✅ Yes | ✅ `--detach`, ✅ `--dry-run`, ✅ `--env`, ✅ `--index`, ✅ `--no-tty`, ✅ `--privileged`, ✅ `--user`, ✅ `--workdir`. |
| `export` options | ✅ Yes | ✅ `--dry-run`, ✅ `--index`, ✅ `--output`. |
| `images` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--quiet`. |
| `kill` options | ✅ Yes | ✅ `--dry-run`, ✅ `--remove-orphans`, ✅ `--signal`. |
| `logs` options | ✅ Yes | ✅ `--dry-run`, ✅ `--follow`, ✅ `--index`, ✅ `--no-color`, ✅ `--no-log-prefix`, ✅ `--since`, ✅ `--tail`, ✅ `--timestamps`, ✅ `--until`. |
| `ls` options | ✅ Yes | ✅ `--all`, ✅ `--dry-run`, ✅ `--filter`, ✅ `--format`, ✅ `--quiet`. |
| `pause` options | ✅ Yes | ✅ `--dry-run`. |
| `port` options | ✅ Yes | ✅ `--dry-run`, ✅ `--index`, ✅ `--protocol`. |
| `ps` options | ✅ Yes | ✅ `--all`, ✅ `--dry-run`, ✅ `--filter`, ✅ `--format`, ✅ `--no-trunc`, ✅ `--orphans`, ✅ `--quiet`, ✅ `--services`, ✅ `--status`. |
| `publish` options | ❌ No | ❌ `--app`, ❌ `--dry-run`, ❌ `--oci-version`, ❌ `--resolve-image-digests`, ❌ `--with-env`, ❌ `--yes`: `publish` is not implemented. |
| `pull` options | ✅ Yes | ✅ `--dry-run`, ✅ `--ignore-buildable`, ✅ `--ignore-pull-failures`, ✅ `--include-deps`, ✅ `--policy`, ✅ `--quiet`. |
| `push` options | ✅ Yes | ✅ `--dry-run`, ✅ `--ignore-push-failures`, ✅ `--include-deps`, ✅ `--quiet`. |
| `restart` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-deps`, ✅ `--timeout`. |
| `rm` options | ✅ Yes | ✅ `--dry-run`, ✅ `--force`, ✅ `--stop`, ✅ `--volumes`. |
| `run` options | ✅ Yes | ✅ `--build`, ✅ `--cap-add`, ✅ `--cap-drop`, ✅ `--detach`, ✅ `--dry-run`, ✅ `--entrypoint`, ✅ `--env`, ✅ `--env-from-file`, ✅ `--interactive`, ✅ `--label`, ✅ `--name`, ✅ `--no-tty`, ✅ `--no-deps`, ✅ `--publish`, ✅ `--pull`, ✅ `--quiet`, ✅ `--quiet-build`, ✅ `--quiet-pull`, ✅ `--remove-orphans`, ✅ `--rm`, ✅ `--service-ports`, ✅ `--use-aliases`, ✅ `--user`, ✅ `--volume`, ✅ `--workdir`. |
| `scale` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-deps`. |
| `start` options | ✅ Yes | ✅ `--dry-run`, ✅ `--wait`, ✅ `--wait-timeout`. |
| `stats` options | ✅ Yes | ✅ `--all`, ✅ `--dry-run`, ✅ `--format`, ✅ `--no-stream`, ✅ `--no-trunc`. |
| `stop` options | ✅ Yes | ✅ `--dry-run`, ✅ `--timeout`. |
| `top` options | ✅ Yes | ✅ `--dry-run`. |
| `unpause` options | ✅ Yes | ✅ `--dry-run`. |
| `up` options | ✅ Yes | ✅ `--abort-on-container-exit`, ✅ `--abort-on-container-failure`, ✅ `--always-recreate-deps`, ✅ `--attach`, ✅ `--attach-dependencies`, ✅ `--build`, ✅ `--detach`, ✅ `--dry-run`, ✅ `--exit-code-from`, ✅ `--force-recreate`, ✅ `--menu`, ✅ `--no-attach`, ✅ `--no-build`, ✅ `--no-color`, ✅ `--no-deps`, ✅ `--no-log-prefix`, ✅ `--no-recreate`, ✅ `--no-start`, ✅ `--pull`, ✅ `--quiet-build`, ✅ `--quiet-pull`, ✅ `--remove-orphans`, ✅ `--renew-anon-volumes`, ✅ `--scale`, ✅ `--timeout`, ✅ `--timestamps`, ✅ `--wait`, ✅ `--wait-timeout`, ✅ `--watch`, ✅ `--yes`. |
| `version` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--short`. |
| `volumes` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--quiet`. |
| `wait` options | ✅ Yes | ✅ `--down-project`, ✅ `--dry-run`. |
| `watch` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-up`, ✅ `--prune`, ✅ `--quiet`. |

## Release Notes

Release notes record the sibling runtime stack through [Tools/release/stack-refs.json](Tools/release/stack-refs.json) so stable releases can highlight user-facing changes from `container`, `containerization`, and `container-builder-shim`, not only commits in this plugin repository.

## Upstream Compatibility

Released Apple `container` compatibility is not a supported-lane functionality gap. The Homebrew preview lane requires the Stephen fork-backed runtime stack and preflights for it before runtime-backed Compose commands run. Stock Apple compatibility remains an upstream/release-channel blocker until equivalent runtime primitives are accepted by Apple and this plugin is updated to consume those upstream APIs.

## Open Follow-ups

- Continue live runtime smoke around progress rendering when touching slow paths. If a local `container compose` run or build appears to hang before any screen output, treat that as a progress regression: reproduce the silent phase, add a focused first-frame test, and emit a Docker Compose-style spinner/status row before the blocking operation begins.

## Next Step

Continue the strict gap scan with `gpus`, arbitrary macOS hardware passthrough, generic service endpoint `driver_opts`, and Deploy device reservations treated as runtime-primitive blockers unless matching Apple-shaped fork primitives are added.
