# Status

This file is the current Docker Compose v2 parity ledger for `container-compose`. Keep branch, release, build, and validation policy in [BUILD.md](BUILD.md), installation guidance in [INSTALL.md](INSTALL.md), and Apple-facing handoff drafts under `docs/upstream/`.

## Current Integration Assumption

`container-compose` is supported as part of the matched `stephenlclarke` runtime bundle. Keep each package lane pinned to the matching `stephenlclarke/container`, `stephenlclarke/containerization`, and `stephenlclarke/container-builder-shim` surfaces until equivalent Apple upstream APIs are accepted and the plugin has been updated to those upstream surfaces.

The main drift risks are logs, events, restart policy, health, exit/completion metadata, networking identity, IPAM/DNS, dynamic ports, copy/archive behavior, build inputs, mounts, secrets/configs, blkio, sysctls, and runtime API shape changes.

Current refs should come from checked-in source-of-truth files rather than duplicated prose: [Tools/release/stack-refs.json](Tools/release/stack-refs.json) records stack component refs, `Package.swift` and [Package.resolved](Package.resolved) record exact SwiftPM dependency resolution, and `container system version` / `container compose version` report installed runtime and plugin provenance after installation.

## Current Validation

Use this validation floor when parity or runtime behavior changes:

- `container-compose`: `make ci`; targeted tests while iterating; full `make docker-compose-parity` whenever Compose, Dockerfile/build, CLI, or runtime behavior changes; and `make release-gate` before stable package dispatch.
- Apple-backed repositories: each affected repository's full source checks and unit tests, plus integration tests for changed runtime behavior.
- Documentation-only changes: the repository Markdown gate over every tracked `.md` file.

## Parity Legend

- ✅ Yes: green tick; Docker Compose v2 parity is implemented for the current `stephenlclarke` runtime lane.
- ⚠️ Partial: orange exclamation; a Docker Compose-compatible subset is implemented and the details list the remaining gap.
- ❌ No: red cross; the surface is intentionally rejected before side effects or has no implementation.

Runtime-backed commands preflight the installed stack and service readiness before work begins. Apple stock or mismatched Homebrew installs fail with [INSTALL.md](INSTALL.md) guidance instead of a late unsupported-feature or runtime error, and stopped services fail before Compose model loading or build/create side effects with `container system start` and Homebrew restart guidance.

Surface names follow the current Docker Docs [Compose file reference](https://docs.docker.com/reference/compose-file/), [Services reference](https://docs.docker.com/reference/compose-file/services/), [Build Specification](https://docs.docker.com/reference/compose-file/build/), [Deploy Specification](https://docs.docker.com/reference/compose-file/deploy/), [Develop Specification](https://docs.docker.com/reference/compose-file/develop/), [Dockerfile reference](https://docs.docker.com/reference/dockerfile/), and [Compose CLI reference](https://docs.docker.com/reference/cli/docker/compose/). This file records current state only; it is not a release history.

## Compose Surface Matrix

| Surface | Parity | Details |
| --- | --- | --- |
| Project discovery and source loading | ✅ Yes | Default local discovery, stdin, environment files, Git resources, and `oci://` project artifacts are implemented. Runtime-backed Compose file attributes are tracked separately below. |
| Service attributes and runtime behavior | ⚠️ Partial | The complete grouped service surface is in [Service Attribute Surface](#service-attribute-surface), including details for every runtime-limited group. |
| Dockerfile and build behavior | ⚠️ Partial | The complete instruction and Build Specification surface is in [Dockerfile And Build Surface](#dockerfile-and-build-surface); image `VOLUME` metadata, `build.no_cache_filter`, and non-file/environment build-secret sources remain limited. |
| CLI commands | ⚠️ Partial | 37 commands are ✅, 9 are ⚠️, and 0 are ❌. These HELP markers cover command invocation and visible command behavior; the full runtime gap register is below. Every command is listed in [CLI Command Surface](#cli-command-surface). |
| CLI long options | ⚠️ Partial | 261 documented long options are ✅, 2 are ⚠️, and 0 are ❌. Every option is listed in [CLI Option Surface](#cli-option-surface). |

## Compose File Surface

The Docker Compose v2 file reference is a rolling Compose Specification surface: top-level project elements, services, networks, volumes, configs, secrets, optional Build/Deploy/Develop specifications, provider/model extensions, fragments, merge behavior, interpolation, profiles, and include behavior. The current parity state is:

| Compose File Surface | Parity | Details |
| --- | --- | --- |
| Project file discovery and sources | ✅ Yes | Default local discovery, explicit and repeated `--file`, `COMPOSE_FILE`, `COMPOSE_ENV_FILES`, `COMPOSE_PROFILES`, `.env`, `--env-file`, project directory/name, profiles, interpolation controls, path-resolution controls, stdin, Git repository resources, and `oci://` Compose project artifacts are implemented. Explicit `--env-file` values override the comma-separated `COMPOSE_ENV_FILES` fallback, including from source-checkout normalizer runs. Git URLs accept Docker's `URL#ref:subdir` syntax, locate canonical Compose filenames in repository directories, resolve relative env/build paths from the checkout, and work in top-level `-f`, `include`, and `extends.file`. OCI project artifacts load Docker Compose project manifests, compose-file layers, env-file layers, OCI 1.0 fallback manifests, OCI 1.1 artifact manifests, image digest override layers, and image-index wrappers. `compose publish` pushes service images and writes OCI project artifacts, image digest override layers, and application image indexes for image-backed projects after Docker-compatible bind-mount, sensitive-data, env-declaration, literal-config, build-only-service, and unresolved-local-include preflights. |
| Top-level `name` and legacy `version` | ✅ Yes | `name` participates in project naming precedence, and legacy `version` is accepted by the Compose Specification loader without driving behavior. |
| Top-level `services` | ⚠️ Partial | Service definitions are parsed and normalized across the current Docker Compose service attribute surface. Runtime-backed gaps are listed in [Service Attribute Surface](#service-attribute-surface), the current-state matrix, and the CLI tables. |
| Top-level `networks` | ⚠️ Partial | `name`, `external`, `internal`, `labels`, the default bridge `driver`, and one IPv4 `ipam` `config.subnet` with optional IPv4 `gateway`, `ip_range`, and `aux_addresses`, plus one IPv6 subnet, are applied. `driver_opts` is currently retained but ignored by the vmnet backend; custom drivers, `attachable`, `enable_ipv4` set `false`, and `enable_ipv6` without an explicit mapped subnet, IPAM `driver`/`options`, IPv6 gateway/allocation range, and multiple same-family pools are not applied. Docker Compose local mode itself ignores IPAM `options`; that is an acceptance/inspection gap rather than a runtime primitive. |
| Top-level `volumes` | ⚠️ Partial | `name`, `external`, `labels`, and local-volume creation are implemented. The runtime records arbitrary `driver` and `driver_opts` metadata but creates a local ext4 volume in every case; only local `size` and `journal` options have behavior. Non-local driver/plugin semantics are unavailable. |
| Top-level `configs` | ✅ Yes | `file`, `environment`, inline `content`, and `external` configs are materialized as read-only service mounts with Compose metadata. External config `name` lookup uses the Compose-owned filesystem backend; see [External Compose Resources](docs/external-resources.md). |
| Top-level `secrets` | ✅ Yes | `file`, `environment`, and `external` secrets are materialized as read-only service mounts and build secrets. External `name` lookup uses the Compose-owned caller Keychain backend; see [External Compose Resources](docs/external-resources.md). |
| Extensions, fragments, merge, and include | ✅ Yes | YAML anchors/fragments, `x-*` extension fields, interpolation, multi-file merge behavior, and local or Git-backed Compose include/extends handling are delegated to `compose-go`. Include short syntax and long-syntax `path`, `project_directory`, and `env_file` are supported; extension data is preserved in normalized config output. |
| Compose Build Specification | ⚠️ Partial | See [Dockerfile And Build Surface](#dockerfile-and-build-surface) for every build attribute and Dockerfile-adjacent behavior. |
| Compose Deploy Specification | ⚠️ Partial | Local behavior maps `replicas`, `labels`, `endpoint_mode`, selected `resources` limits, memory and GPU reservations, and some `restart_policy` metadata. `resources.reservations.memory` projects through the generic soft-memory runtime primitive, matching Docker Compose local mode. CPU/pids/generic reservations and device/generic limits are not mapped. `mode`, `placement`, `update_config`, and `rollback_config` must be accepted and preserved for local-mode parity but do not require a Swarm scheduler. |
| Compose Develop Specification | ✅ Yes | `develop` `watch` rules support `path`, `action`, `target`, `ignore`, `include`, `initial_sync`, and `exec` metadata for `rebuild`, `restart`, `sync`, `sync+restart`, and `sync+exec`, including prune, `watch --no-up`, `up --watch`, and `up --menu --watch`. |
| Provider services and models | ⚠️ Partial | Provider services run through the Compose provider `type`/`options` protocol and inject provider variables into dependents. Top-level model `model`, `context_size`, and `runtime_flags` plus service model `endpoint_var`/`model_var` are parsed and rendered, but model-runner startup and endpoint injection are rejected until a backend exists. |

## Service Attribute Surface

Docker Compose service attributes are grouped here by runtime behavior so every current service surface has a yes/no/partial indicator without turning this handoff into generated API documentation.

| Service Attribute Surface | Parity | Details |
| --- | --- | --- |
| Identity, image, process, and profile attributes | ⚠️ Partial | `image`, `platform`, `pull_policy`, `profiles`, `attach`, `container_name`, `hostname`, `domainname`, non-empty `command` and `entrypoint`, `working_dir`, `user`, `stdin_open`, `tty`, `init`, `runtime`, and `scale` are mapped into local orchestration; `extends` is resolved during project loading. Explicit empty-list `command: []` and `entrypoint: []` clearing is lost at the normalizer/runtime boundary. |
| Labels, annotations, and extension metadata | ⚠️ Partial | `labels`, `label_file`, service `x-*` extensions, container names, project labels, and service metadata are retained. `annotations` is collapsed into labels because the runtime has no distinct OCI/runtime annotation field. |
| Environment and env files | ✅ Yes | `environment` and `env_file` short/long syntax are implemented, including optional missing env files and `format: raw` values. Service env files are resolved during normalization like Docker Compose and are not forwarded as runtime `--env-file` arguments. |
| Build-backed services | ⚠️ Partial | `build` string syntax and the implemented Build Specification subset are mapped through the supported Dockerfile/build surface. `build.no_cache_filter` is omitted, and build-secret source shapes other than file/environment are rejected; Docker Compose local mode ignores build-secret `uid`, `gid`, and `mode` metadata. |
| Dependencies and links | ⚠️ Partial | `depends_on` and `external_links` ordering/discovery are implemented, including `condition: service_completed_successfully`, `condition: service_healthy`, and dependency restart/required metadata where local mode can honor it. Legacy service `links` resolves each linked service's current IPv4 attachment into a source-container static host entry after dependency creation; source and target must share exactly one normalized Compose network, and aliases colliding case-insensitively with source `extra_hosts`, another linked service, or an external link are rejected before side effects. `external_links` likewise resolves a static host entry when its source and external container share exactly one runtime network, even if the source has other attachments. Dynamic source-scoped DNS aliases, direct network `aliases`, legacy or external links with zero or multiple shared networks, address-change propagation outside Compose reconciliation, and richer external-service discovery remain runtime gaps. |
| Ports and exposure | ⚠️ Partial | `ports` short/long syntax, dynamic host ports, ranges, host IPs, protocols, named/app-protocol metadata, and `port` lookup are implemented. Service `expose` is parsed but never reaches the runtime because the container configuration lacks an exposed-port field. |
| Network attachments and discovery | ⚠️ Partial | Multiple `networks` attachments, `network_mode` values `none`/`host`, MTU-only endpoint `driver_opts`, `mac_address`, route/connection priority, interface name, static IPv4/IPv6 addresses, `link_local_ips`, `dns`, `dns_opt`, `dns_search`, and `extra_hosts` are applied where matching primitives exist. The runtime has no container-facing, network-scoped embedded DNS: service/container names, direct `networks.aliases`, `run --use-aliases`, dynamic address updates, and complete `links`/`external_links` semantics are unavailable. Arbitrary endpoint `driver_opts`, `network_mode` values `service:NAME`/`container:NAME`, and bridge/custom-name network modes are unavailable. |
| Volumes, mounts, configs, and secrets | ⚠️ Partial | Named, bind, anonymous, `tmpfs`, read-only image, `configs`, and `secrets` mounts work for the implemented local `volumes` subset, including `volumes_from`, local `volume_driver`, and supported subpaths. Dockerfile-declared image volumes do not materialize because OCI image `Volumes` metadata is absent; anonymous-volume naming can collide across services/one-off containers with the same target. Docker copy-up and `volume.nocopy` semantics, non-local volume drivers, recursive bind modes, consistency/cache modes, and `use_api_socket` are unavailable. SELinux relabeling, `npipe`, and cluster/CSI mounts are platform or Swarm-specific. |
| Runtime resources and security | ⚠️ Partial | Positive fractional `cpus`, `cpu_period`, `cpu_quota`, `cpu_shares`, `cpuset`, byte-accurate `mem_limit`, `mem_reservation`, `deploy.resources.reservations.memory`, `memswap_limit`, `pids_limit`, `cgroup`, `pid`, `ipc`, and `uts` modes `host` and `private`, `userns_mode` values `host` and `private`, `blkio_config`, `sysctls`, `ulimits`, `shm_size`, `oom_score_adj`, `cap_add`, `cap_drop`, `read_only`, restart, numeric/named `group_add`, and `security_opt` values `no-new-privileges:true`, `no-new-privileges:false`, and `seccomp=unconfined` are handled. The unconfined seccomp value is consumed by Compose because the guest workload baseline already has no seccomp filter; no synthetic runtime flag is needed. Docker Compose V2 normalizes `cpus: 0` / `0.000` to no runtime CPU limit; container-compose does the same, while the generic runtime also accepts explicit `--cpus 0` as cgroup v2 unlimited (`cpu.max = max PERIOD`). Fractional and explicit CFS settings are applied through the macOS Linux guest's cgroup v2 `cpu.max`; OCI CPU shares are converted to cgroup v2 `cpu.weight`; `cpuset` is applied to the macOS Linux guest cgroup after initializing its required memory-node set; `cgroup`, `pid`, `ipc`, and `uts` host modes omit the matching OCI namespace so they select the sandbox VM namespace, while private remains the default. `userns_mode` `host` retains the sandbox VM's existing user namespace; `private` creates an identity-mapped (`0 0 4294967295`) namespace inside that guest. Neither mode joins or exposes a macOS host namespace. Private mode requires the matched Container, Containerization, and guest `vminitd` image shipped by the current stack. `stop_signal` and `stop_grace_period` are persisted as per-container runtime defaults. Docker Compose's local Deploy memory reservation reuses the generic soft-memory runtime primitive. For initial `privileged` containers, the generic runtime restores all Linux capabilities and clears Containerization's standard OCI masked/read-only paths inside the sandbox VM. `cpu_rt_period` and `cpu_rt_runtime`; `mem_swappiness`, `oom_kill_disable`, `cgroup_parent`, IPC sharing (`ipc: shareable`, `ipc: service:NAME`, and accepted `ipc: container:NAME`), PID sharing (`pid: service:NAME` and `pid: container:NAME`), custom user-namespace mappings, profile-based `security_opt` forms, and `storage_opt` are unavailable. `privileged` containers still cannot provide Docker's host-device, device-cgroup, security-profile, or host-isolation behavior. `cpu_count`, `cpu_percent`, `isolation`, and `credential_spec` are Windows-specific. |
| Devices, GPU, and credentials | ⚠️ Partial | `devices`, `device_cgroup_rules`, service `gpus`, and Deploy generic GPU reservations are implemented through the `stephenlclarke` runtime. GPU requests attach the single Apple virtio-gpu VM device and project Linux DRM character-device metadata when the running guest kernel exposes `/dev/dri`; vendor drivers such as NVIDIA/CUDA, multiple GPUs, driver options, non-GPU device reservations, `credential_spec`, arbitrary macOS hardware passthrough, and verified hardware-accelerated rendering remain runtime gaps. |
| Logging | ⚠️ Partial | `logging` drivers `none`, `json-file`, and `local` are accepted, with `max-size`/`max-file` validation, but `json-file` and `local` both use the same Apple local logger. Docker driver behavior and plugins (`syslog`, `journald`, `fluentd`, `gelf`, `awslogs`, `splunk`, and others), `mode`, `max-buffer-size`, and driver-specific options are unavailable. |
| Healthchecks | ✅ Yes | `healthcheck` and Dockerfile `HEALTHCHECK` defaults/overrides are projected into typed runtime configuration. Probe cadence and state, `service_healthy`, health-aware `up/start --wait`, transition events, and `ps` health output are implemented. |
| Lifecycle hooks | ⚠️ Partial | `post_start` and `pre_stop` run on detached/managed paths, regular foreground `up`, and non-interactive foreground `run`. The pinned runtime already provides interactive init-process stream reattachment, but this plugin does not use it for foreground `run` hooks. Docker Compose implements `pre_start` by creating an ephemeral helper with inherited mounts/networks; the required container primitives exist in the pinned lane, but the Compose adapter does not orchestrate it. `per_replica: true` is rejected by Docker Compose itself. |
| Deploy Specification attributes | ⚠️ Partial | `deploy` replicas, labels, endpoint metadata, selected limits, memory reservations, and GPU reservation metadata are handled locally. `resources.reservations.memory` reuses the existing soft-memory primitive; CPU/pids/generic reservations, non-GPU devices, and device/generic limits are unmapped. Docker Compose local mode does not provide Swarm placement, rolling-update, rollback, or job scheduling; local-mode parity requires compatible parsing/preservation rather than implementing a scheduler. |
| Develop Specification attributes | ✅ Yes | `develop` watch rules support `rebuild`, `restart`, `sync`, `sync+restart`, and `sync+exec`, including `path`, `action`, `target`, `ignore`, `include`, `initial_sync`, and `exec` metadata. |
| Provider and model attributes | ⚠️ Partial | `provider` services use `type` and `options`, run through the Compose provider protocol, and inject variables into dependents. Service `models` with `endpoint_var`/`model_var` and top-level `models` with `model`/`context_size`/`runtime_flags` are parsed and rendered by `config`, but runtime model-runner startup and endpoint injection are rejected until a backend exists. |

## Dockerfile And Build Surface

| Dockerfile / Build Surface | Parity | Details |
| --- | --- | --- |
| Dockerfile instruction set and parser directives | ⚠️ Partial | The `stephenlclarke/container build` BuildKit path parses `syntax`, `escape`, and `check` directives, here-documents, shell/exec forms, and the current Dockerfile instructions: `ADD`, `ARG`, `CMD`, `COPY`, `ENTRYPOINT`, `ENV`, `EXPOSE`, `FROM`, `HEALTHCHECK`, `LABEL`, `MAINTAINER`, `ONBUILD`, `RUN`, `SHELL`, `STOPSIGNAL`, `USER`, `VOLUME`, and `WORKDIR`. `VOLUME` metadata is not retained in OCI image configuration, so declared anonymous volumes are not created at runtime. |
| `.dockerignore` context filtering | ✅ Yes | Build contexts use the `stephenlclarke/container-builder-shim` filter path, including negation patterns that re-include descendants below excluded parent directories. |
| Build context string syntax | ✅ Yes | `build: ./dir` resolves to a context directory with the default `Dockerfile`, matching Docker Compose local mode. |
| `build.context` | ✅ Yes | Local relative and absolute contexts are resolved, and remote BuildKit references are passed through to the builder. |
| `build.dockerfile` | ✅ Yes | Alternate Dockerfile paths are resolved relative to the effective build context, including remote-context pass-through. |
| `build.dockerfile_inline` | ✅ Yes | Inline Dockerfiles are materialized for live builds and rendered as `dockerfile-inline` in `build --print` bake output. |
| `build.additional_contexts` | ✅ Yes | Local, image, Git/URL-style, and `service:NAME` contexts are mapped to BuildKit `--build-context` or bake contexts; service contexts are built in dependency order. Stock Apple tracking for the same `container build` primitive is [apple/container#1930](https://github.com/apple/container/issues/1930). |
| `build.args` and `build --build-arg` | ✅ Yes | Compose-file and CLI build arguments merge with Docker Compose-compatible environment lookup for key-only CLI args. |
| `build.cache_from` and `build.cache_to` | ✅ Yes | Cache hints are forwarded to live builds and bake output. |
| `build.entitlements` | ✅ Yes | Entitlements are forwarded as BuildKit `--allow` values. |
| `build.extra_hosts` | ✅ Yes | Build-time host entries are forwarded to the builder. |
| `build.isolation` | ✅ Yes | The field is accepted and preserved in normalized config; local Docker Compose omits it from Buildx bake output on this platform, and this plugin mirrors that behavior. |
| `build.labels` | ✅ Yes | Build labels are forwarded to live builds and bake output. |
| `build.network` | ✅ Yes | BuildKit network mode is forwarded to live builds and bake output. |
| `build.no_cache` and `--no-cache` | ✅ Yes | File and CLI no-cache controls are applied to live builds and bake output. |
| `build.no_cache_filter` | ⚠️ Partial | Docker Compose forwards this stage filter to Buildx bake, but the normalizer omits it before both live build and `build --print`; the builder lane needs a filter-valued no-cache input rather than the current Boolean only. |
| `build.platforms` | ✅ Yes | Target platforms are forwarded to live builds and bake output. |
| `build.privileged` | ✅ Yes | Privileged build mode is forwarded to the `stephenlclarke` builder. |
| `build.provenance` | ✅ Yes | Compose-file and CLI provenance attestations are forwarded, including Docker Compose-compatible false/disabled handling. |
| `build.pull` and `--pull` | ✅ Yes | File and CLI pull controls are applied to live builds and bake output. |
| `build.sbom` | ✅ Yes | Compose-file and CLI SBOM attestations are forwarded, including Docker Compose-compatible false/disabled handling. |
| `build.secrets` | ⚠️ Partial | File-backed and environment-backed BuildKit secret IDs are supported. Docker Compose local mode ignores `uid`, `gid`, and `mode` metadata for build secrets, so that is not a runtime gap; source shapes other than file/environment are an adapter acceptance gap. |
| `build.ssh` and `build --ssh` | ✅ Yes | Compose-file and CLI SSH forwarding entries are merged with Docker Compose-compatible CLI override behavior by SSH ID. |
| `build.shm_size` | ✅ Yes | Build shared-memory size is forwarded to the builder. |
| `build.tags` | ✅ Yes | Additional image tags are forwarded and de-duplicated with the service image tag. |
| `build.target` | ✅ Yes | Target stages are forwarded to live builds and bake output. |
| `build.ulimits` | ✅ Yes | Build ulimits are forwarded to the builder. |
| `build --builder` | ✅ Yes | Named `stephenlclarke` builders are selected for live builds; `build --print` omits builder selection from bake JSON like Docker Compose. |
| `build --check` | ✅ Yes | BuildKit lint/check mode runs without exporting an image; `build --print --check` emits bake `call: "lint"`. |
| `build --print` | ✅ Yes | Buildx bake JSON is rendered without build side effects and includes supported contexts, args, cache, labels, tags, target, platforms, pull/no-cache, secrets, SSH, attestations, outputs, and lint calls. |
| Dockerfile `HEALTHCHECK` inheritance | ✅ Yes | Dockerfile healthcheck metadata is inherited through the `stephenlclarke` image metadata API, explicit Compose overrides merge with image defaults, and the resulting probes drive dependency gating, health-aware waits, events, and status output. |

## CLI Command Surface

| Command | Parity | Details |
| --- | --- | --- |
| `alpha` | ✅ Yes | Experimental namespace help and the Docker-documented dry-run, scale, and watch aliases are implemented. |
| `alpha dry-run` | ✅ Yes | Experimental `alpha dry-run -- COMMAND` wraps the requested Compose command with root `--dry-run` while preserving project/global options. |
| `alpha scale` | ✅ Yes | Experimental `alpha scale` is implemented as an alias for the stable `scale` command. |
| `alpha watch` | ✅ Yes | Experimental `alpha watch` is implemented as an alias for the stable `watch` command. |
| `attach` | ✅ Yes | Interactive init-process stream reattachment, `--sig-proxy`, and Docker-compatible `--detach-keys` are implemented through the forked runtime primitive tracked by [apple/container#378](https://github.com/apple/container/issues/378); output-only attach continues to follow persisted logs. |
| `bridge` | ✅ Yes | The complete Compose Bridge CLI runtime is implemented for the `stephenlclarke` runtime lane. |
| `bridge convert` | ✅ Yes | Models include image ports, published target ports, and text or binary config and secret content; Kubernetes, Helm, custom templates, repeated transformations, and empty-output current-directory mode run through local transformer images. |
| `bridge transformations` | ✅ Yes | Bridge transformation image management is implemented. |
| `bridge transformations create` | ✅ Yes | A stopped transformer rootfs is exported, only `/templates` is securely extracted, and a standard rebuildable Dockerfile is written. |
| `bridge transformations list` | ✅ Yes | Local transformer images labelled `com.docker.compose.bridge=transformation` are listed in Docker-shaped table, JSON, and quiet modes. |
| `bridge transformations ls` | ✅ Yes | Alias for `bridge transformations list`. |
| `build` | ⚠️ Partial | Build execution and CLI options work for the implemented build surface, but `build.no_cache_filter` is omitted before live and bake builds and non-file/environment build-secret sources are rejected. |
| `commit` | ✅ Yes | Stopped service containers and running containers commit to OCI images through export, archive creation, and image load. The generated image preserves Docker `Healthcheck` metadata and effective Compose healthcheck overrides. The default `--pause=true` running path briefly freezes the root filesystem; `--pause=false` uses the generic best-effort APFS copy-on-write snapshot in the pinned `stephenlclarke/container` fork and leaves the filesystem writable. Omitted `--index` and `--index=0` use Docker Compose's default service-container selection. |
| `config` | ⚠️ Partial | Compose project rendering and config query options are implemented, but normalized output omits `build.no_cache_filter`. |
| `convert` | ✅ Yes | Docker Compose's config-compatible model conversion projections are implemented for the documented local output modes. |
| `cp` | ✅ Yes | Local-to-service, service-to-local, service-to-service, stdin tar archive, and stdout tar archive copies are implemented, including archive, follow-link, replica-index, and one-off-container modes. |
| `create` | ✅ Yes | Service creation, build/pull/recreate controls, scaling, and orphan handling are implemented. |
| `down` | ✅ Yes | Container, network, image, volume, timeout, orphan, and service-scoped cleanup are implemented. |
| `events` | ⚠️ Partial | Event output, JSON mode, and time filters are implemented, but the runtime exposes only create/start/pause/unpause/stop/delete/health events rather than Docker's full action vocabulary such as die, destroy, kill, oom, restart, rename, resize, update, attach/detach, and exec. |
| `exec` | ⚠️ Partial | Service exec options, indexes, env, user, workdir, tty, and detach mode are implemented. `--privileged` grants capabilities but cannot provide Docker's full privileged isolation/device behavior. |
| `export` | ✅ Yes | Container filesystem export to an archive path is implemented for stopped containers and automatically uses the generic live snapshot path for running service containers. |
| `help` | ✅ Yes | A deliberate `container compose help` extension returns Compose-layer help because `container help compose` cannot dispatch to the plugin. Docker Compose-compatible `--help`/`-h` remain available for every command. |
| `images` | ✅ Yes | Image listing and formatting are implemented. |
| `kill` | ✅ Yes | Signal and orphan handling are implemented. |
| `logs` | ✅ Yes | Follow, timestamps, prefix/color controls, indexes, tail, and time filters are implemented. |
| `ls` | ✅ Yes | Project listing, filters, formats, quiet, and all modes are implemented. |
| `pause` | ✅ Yes | Service pause is implemented. |
| `port` | ✅ Yes | Published-port lookup by service, index, and protocol is implemented. |
| `ps` | ⚠️ Partial | Container listing, filters, statuses, service selection, table/JSON output, field references, and Docker's row-formatting functions are implemented. Go-template control blocks and nested object paths are rejected before discovery; map/range traversal is not available for the flat command row; see [the Compose-owned template handoff](docs/upstream/container-compose/PR-compose-output-template-actions.md). |
| `publish` | ✅ Yes | Service image push, OCI project artifact publishing, image digest override layers, and `--app` application image indexes are implemented for image-backed Compose projects. Supported publish behavior includes all-profile image selection, `--dry-run`, `--app`, `--oci-version`, `--resolve-image-digests`, `--with-env`, Docker-compatible interactive preflight prompts, and noninteractive `--yes` prompt acceptance. |
| `pull` | ✅ Yes | Pull policy, dependency inclusion, quiet mode, and ignore-failure behavior are implemented. |
| `push` | ✅ Yes | Dependency inclusion, quiet mode, and ignore-failure behavior are implemented. |
| `restart` | ✅ Yes | Service restart, dependency control, and timeout are implemented. |
| `rm` | ✅ Yes | Stopped-container removal, force, stop, and volume cleanup are implemented. |
| `run` | ⚠️ Partial | One-off containers and Docker Compose run options are implemented except `--use-aliases`/container-facing DNS and interactive foreground lifecycle-hook execution. |
| `scale` | ✅ Yes | Service scaling and dependency control are implemented. |
| `start` | ✅ Yes | Start, health-aware wait, and wait-timeout behavior are implemented. |
| `stats` | ⚠️ Partial | Table/JSON formatting, stopped-container inclusion, no-stream, no-trunc, field references, and Docker's row-formatting functions are implemented. Go-template control blocks and nested object paths are rejected before runtime sampling; map/range traversal is not available for the flat command row; see [the Compose-owned template handoff](docs/upstream/container-compose/PR-compose-output-template-actions.md). |
| `stop` | ✅ Yes | Stop and timeout are implemented. |
| `top` | ✅ Yes | Service selection and Docker-shaped per-container process tables are implemented through the matched runtime process-metadata API, including UID, PID, PPID, CPU, STIME, TTY, TIME, and CMD columns. |
| `unpause` | ✅ Yes | Service unpause is implemented. |
| `up` | ⚠️ Partial | Create/start/attach/watch/menu/build/pull/recreate/exit-control/log-output/scaling behavior and health-aware `--wait`/`--wait-timeout` are implemented. `pre_start` and container-facing DNS aliases remain unavailable. |
| `version` | ✅ Yes | Pretty, short, and JSON version output are implemented. |
| `volumes` | ⚠️ Partial | Volume listing, quiet, table/JSON output, field references, and Docker's row-formatting functions are implemented. Go-template control blocks and nested object paths are rejected before volume discovery; map/range traversal is not available for the flat command row; see [the Compose-owned template handoff](docs/upstream/container-compose/PR-compose-output-template-actions.md). |
| `wait` | ✅ Yes | Container exit waiting and `--down-project` cleanup are implemented. |
| `watch` | ✅ Yes | Develop watch actions and options are implemented. |

## CLI Option Surface

`container compose --help` and `container compose COMMAND --help` are the authoritative usage views. Every documented long option surface is listed here with per-option parity markers.

A ✅ option means the flag itself is parsed and mapped for the current command behavior. Command parity is still a separate axis; command rows above describe any remaining operand or runtime limitations that are not represented as long options.

| Option Surface | Parity | Details |
| --- | --- | --- |
| Root options | ✅ Yes | ✅ `--all-resources`: selected-service `config` and `convert` output keeps unreferenced top-level networks, volumes, configs, and secrets, ✅ `--ansi` and `COMPOSE_ANSI`, ✅ `--compatibility` and `COMPOSE_COMPATIBILITY`: use Docker Compose legacy underscore separators for generated service and one-off container names, ✅ `--dry-run`, ✅ `--env-file` with comma-separated `COMPOSE_ENV_FILES` fallback, ✅ `--file`, ✅ `COMPOSE_IGNORE_ORPHANS` and `COMPOSE_REMOVE_ORPHANS`: suppress or remove project orphans, ✅ `COMPOSE_MENU`, ✅ `--parallel` and `COMPOSE_PARALLEL_LIMIT`: limit independent pull, push, and build engine operations, with `-1` as the unlimited default; dependency-sensitive lifecycle orchestration remains ordered, ✅ `--profile` and `COMPOSE_PROFILES`, ✅ `--progress` and `COMPOSE_PROGRESS`, ✅ `--project-directory`, ✅ `--project-name`, ✅ `COMPOSE_STATUS_STDOUT`: routes Compose-owned status/progress to stdout, ✅ `--verbose`. `COMPOSE_FILE`, `COMPOSE_PROJECT_NAME`, `COMPOSE_PATH_SEPARATOR`, and `COMPOSE_DISABLE_ENV_FILE` are compose-go root-loading defaults. `COMPOSE_CONVERT_WINDOWS_PATHS` is Windows-only and is not applicable to this macOS/Linux runtime. |
| `alpha` options | ✅ Yes | ✅ `--dry-run`. |
| `alpha dry-run` options | ✅ Yes | ✅ `--dry-run`: accepted and implied for the wrapped command. |
| `alpha scale` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-deps`. |
| `alpha watch` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-up`, ✅ `--quiet`. |
| `attach` options | ✅ Yes | ✅ `--detach-keys`: forwarded to the interactive runtime stream relay and ignored for output-only attach, ✅ `--dry-run`, ✅ `--index`, ✅ `--no-stdin`, ✅ `--sig-proxy`. |
| `bridge` options | ✅ Yes | ✅ `--dry-run`. |
| `bridge convert` options | ✅ Yes | ✅ `--dry-run`, ✅ `--output`, ✅ `--templates`, ✅ `--transformation`. |
| `bridge transformations` options | ✅ Yes | ✅ `--dry-run`. |
| `bridge transformations create` options | ✅ Yes | ✅ `--dry-run`, ✅ `--from`. |
| `bridge transformations list` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--quiet`. |
| `bridge transformations ls` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--quiet`. |
| `build` options | ✅ Yes | ✅ `--build-arg`, ✅ `--builder`, ✅ `--check`, ✅ `--dry-run`, ✅ `--memory`, ✅ `--no-cache`, ✅ `--print`, ✅ `--provenance`, ✅ `--pull`, ✅ `--push`, ✅ `--quiet`, ✅ `--sbom`, ✅ `--ssh`, ✅ `--with-dependencies`. |
| `commit` options | ✅ Yes | ✅ `--author`, ✅ `--change`, ✅ `--dry-run`, ✅ `--index`, ✅ `--message`, ✅ `--pause`: the default uses a brief filesystem-consistent live snapshot for running containers; `--pause=false` uses a best-effort no-freeze snapshot. |
| `config` options | ✅ Yes | ✅ `--dry-run`, ✅ `--environment`, ✅ `--format`, ✅ `--hash`, ✅ `--images`, ✅ `--lock-image-digests`, ✅ `--models`, ✅ `--networks`, ✅ `--no-consistency`, ✅ `--no-env-resolution`, ✅ `--no-interpolate`, ✅ `--no-normalize`, ✅ `--no-path-resolution`, ✅ `--output`, ✅ `--profiles`, ✅ `--quiet`, ✅ `--resolve-image-digests`, ✅ `--services`, ✅ `--variables`, ✅ `--volumes`. |
| `convert` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--hash`, ✅ `--images`, ✅ `--no-consistency`, ✅ `--no-interpolate`, ✅ `--no-normalize`, ✅ `--output`, ✅ `--profiles`, ✅ `--quiet`, ✅ `--resolve-image-digests`, ✅ `--services`, ✅ `--volumes`. |
| `cp` options | ✅ Yes | ✅ `--all`, ✅ `--archive`, ✅ `--dry-run`, ✅ `--follow-link`, ✅ `--index`. |
| `create` options | ✅ Yes | ✅ `--build`, ✅ `--dry-run`, ✅ `--force-recreate`, ✅ `--no-build`, ✅ `--no-recreate`, ✅ `--pull`, ✅ `--quiet-pull`, ✅ `--remove-orphans`, ✅ `--scale`, ✅ `--yes`. |
| `down` options | ✅ Yes | ✅ `--dry-run`, ✅ `--remove-orphans`, ✅ `--rmi`, ✅ `--timeout`, ✅ `--volumes`. |
| `events` options | ✅ Yes | ✅ `--dry-run`, ✅ `--json`, ✅ `--since`, ✅ `--until`. |
| `exec` options | ⚠️ Partial | ✅ `--detach`, ✅ `--dry-run`, ✅ `--env`, ✅ `--index`, ✅ `--no-tty`, ⚠️ `--privileged` (capabilities only; Docker-complete privileged isolation/device behavior is unavailable), ✅ `--user`, ✅ `--workdir`. |
| `export` options | ✅ Yes | ✅ `--dry-run`, ✅ `--index`, ✅ `--output`. |
| `images` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--quiet`. |
| `kill` options | ✅ Yes | ✅ `--dry-run`, ✅ `--remove-orphans`, ✅ `--signal`. |
| `logs` options | ✅ Yes | ✅ `--dry-run`, ✅ `--follow`, ✅ `--index`, ✅ `--no-color`, ✅ `--no-log-prefix`, ✅ `--since`, ✅ `--tail`, ✅ `--timestamps`, ✅ `--until`. |
| `ls` options | ✅ Yes | ✅ `--all`, ✅ `--dry-run`, ✅ `--filter`, ✅ `--format`, ✅ `--quiet`. |
| `pause` options | ✅ Yes | ✅ `--dry-run`. |
| `port` options | ✅ Yes | ✅ `--dry-run`, ✅ `--index`, ✅ `--protocol`. |
| `ps` options | ✅ Yes | ✅ `--all`, ✅ `--dry-run`, ✅ `--filter`, ✅ `--format` (the option is fully parsed and mapped; its row-template language limit is tracked on the command row), ✅ `--no-trunc`, ✅ `--orphans`, ✅ `--quiet`, ✅ `--services`, ✅ `--status`. |
| `publish` options | ✅ Yes | ✅ `--app`: publish an application image index linked to the Compose project artifact, ✅ `--dry-run`, ✅ `--oci-version`, ✅ `--resolve-image-digests`, ✅ `--with-env`, ✅ `--yes`. |
| `pull` options | ✅ Yes | ✅ `--dry-run`, ✅ `--ignore-buildable`, ✅ `--ignore-pull-failures`, ✅ `--include-deps`, ✅ `--policy`, ✅ `--quiet`. |
| `push` options | ✅ Yes | ✅ `--dry-run`, ✅ `--ignore-push-failures`, ✅ `--include-deps`, ✅ `--quiet`. |
| `restart` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-deps`, ✅ `--timeout`. |
| `rm` options | ✅ Yes | ✅ `--dry-run`, ✅ `--force`, ✅ `--stop`, ✅ `--volumes`. |
| `run` options | ⚠️ Partial | ✅ `--build`, ✅ `--cap-add`, ✅ `--cap-drop`, ✅ `--detach`, ✅ `--dry-run`, ✅ `--entrypoint`, ✅ `--env`, ✅ `--env-from-file`, ✅ `--interactive`, ✅ `--label`, ✅ `--name`, ✅ `--no-tty`, ✅ `--no-deps`, ✅ `--publish`, ✅ `--pull`, ✅ `--quiet`, ✅ `--quiet-build`, ✅ `--quiet-pull`, ✅ `--remove-orphans`, ✅ `--rm`, ✅ `--service-ports`, ⚠️ `--use-aliases` (requires container-facing DNS), ✅ `--user`, ✅ `--volume`, ✅ `--workdir`. |
| `scale` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-deps`. |
| `start` options | ✅ Yes | ✅ `--dry-run`, ✅ `--wait`, ✅ `--wait-timeout`. |
| `stats` options | ✅ Yes | ✅ `--all`, ✅ `--dry-run`, ✅ `--format` (the option is fully parsed and mapped; its row-template language limit is tracked on the command row), ✅ `--no-stream`, ✅ `--no-trunc`. |
| `stop` options | ✅ Yes | ✅ `--dry-run`, ✅ `--timeout`. |
| `top` options | ✅ Yes | ✅ `--dry-run`. |
| `unpause` options | ✅ Yes | ✅ `--dry-run`. |
| `up` options | ✅ Yes | ✅ `--abort-on-container-exit`, ✅ `--abort-on-container-failure`, ✅ `--always-recreate-deps`, ✅ `--attach`, ✅ `--attach-dependencies`, ✅ `--build`, ✅ `--detach`, ✅ `--dry-run`, ✅ `--exit-code-from`, ✅ `--force-recreate`, ✅ `--menu`, ✅ `--no-attach`, ✅ `--no-build`, ✅ `--no-color`, ✅ `--no-deps`, ✅ `--no-log-prefix`, ✅ `--no-recreate`, ✅ `--no-start`, ✅ `--pull`, ✅ `--quiet-build`, ✅ `--quiet-pull`, ✅ `--remove-orphans`, ✅ `--renew-anon-volumes`, ✅ `--scale`, ✅ `--timeout`, ✅ `--timestamps`, ✅ `--wait`, ✅ `--wait-timeout`, ✅ `--watch`, ✅ `--yes`. |
| `version` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--short`. |
| `volumes` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format` (the option is fully parsed and mapped; its row-template language limit is tracked on the command row), ✅ `--quiet`. |
| `wait` options | ✅ Yes | ✅ `--down-project`, ✅ `--dry-run`. |
| `watch` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-up`, ✅ `--prune`, ✅ `--quiet`. |

## Upstream Compatibility

Released Apple `container` compatibility is not a supported-lane functionality gap. The Homebrew release lane requires the matched `stephenlclarke` runtime stack and preflights for it before runtime-backed Compose commands run. Stock Apple compatibility remains an upstream/release-channel blocker until equivalent runtime primitives are accepted by Apple and this plugin is updated to consume those upstream APIs.

## Runtime Gap Register

This is the complete known runtime and adapter gap register from the Docker Compose v5.3.1 audit on 2026-07-18. It distinguishes a missing Apple/fork runtime primitive from a `container-compose` adapter gap and from a Docker platform feature that local macOS Compose does not need to emulate. The surface tables above are the concise ledger; this section is the implementation backlog behind their partial markers.

| Area | Missing Apple/fork runtime behavior | Compose adapter or compatibility work | Scope notes |
| --- | --- | --- | --- |
| CPU and memory controls | `cpu_rt_period`, `cpu_rt_runtime`, `mem_swappiness`, and `oom_kill_disable`. | No additional adapter work remains for fractional `cpus`, Docker Compose V2's zero/no-limit normalization, `cpu_period`, `cpu_quota`, or `cpuset`. | Positive fractional `cpus`, Docker Compose V2-compatible `cpus: 0` normalization, direct generic zero/unlimited CPU limits, explicit cgroup v2 CPU quota/period, CPU sets, integral CPU counts, byte-accurate hard memory limits, CPU shares, service/Deploy memory reservation, memory swap, and pids limits work. |
| Isolation and security | A cgroup-parent lifecycle that callers can name and administer, IPC sharing (`ipc: shareable`, `ipc: service:NAME`, and accepted `ipc: container:NAME`), PID sharing (`pid: service:NAME` and `pid: container:NAME`), custom user-namespace mappings, SELinux/AppArmor/seccomp profiles and other `security_opt` forms, and Docker-complete privileged behavior (host devices, device cgroups, security profiles, and host isolation). | No remaining adapter work for host/private `cgroup`, PID, IPC, UTS, or user namespaces, persisted `stop_signal`, `stop_grace_period`, or `security_opt: seccomp=unconfined`; retain the unsupported diagnostics for the remaining primitives. | `cgroup_parent` is Phase 6: the lower runtime owns the guest cgroup hierarchy and exposes no parent-cgroup lifecycle or operator limit/control surface, so nesting an opaque path would not implement Docker semantics. `cgroup`, `pid`, `ipc`, and `uts` host modes omit their OCI namespace entries so the container uses the matching sandbox VM namespace; `private` remains the default OCI namespace. `userns_mode: host` preserves the sandbox VM user namespace, while `private` creates an identity-mapped (`0 0 4294967295`) namespace inside that guest through the matched guest `vminitd`; neither mode accesses a macOS host namespace. Arbitrary UID/GID mapping shapes remain unsupported. `security_opt` values `no-new-privileges:true` and `no-new-privileges:false` use the generic Linux guest primitive; `seccomp=unconfined` matches the existing guest workload baseline without a runtime argument. `cpu_count`, `cpu_percent`, `isolation`, and `credential_spec` are Windows-only. |
| Networks and names | Container-facing, network-scoped embedded DNS that resolves service/container names and aliases; namespace sharing for `network_mode: service:NAME`/`container:NAME`; arbitrary bridge/custom-name network modes; custom network drivers; custom IPAM drivers. | Source-scoped `networks.aliases`, `run --use-aliases`, complete `links`/`external_links`, dynamic address propagation, legacy link environment semantics, endpoint `driver_opts` beyond MTU, and retained `attachable` state. | Existing runtime attachment, static IPAM, `extra_hosts`, host/none modes, MTU, priorities, and interface naming remain usable. |
| IPAM | IPv6 allocation without an explicit subnet, IPv6 gateway/range/auxiliary-address handling, multiple pools of one family, and disabled IPv4. | Accept/preserve IPAM `options` for inspection parity. | Docker Compose local mode ignores IPAM `options`; it is not an Apple runtime behavior gap. |
| Volumes and mounts | OCI image `Volumes` metadata and automatic image-declared anonymous volumes; Docker volume copy-up and `volume.nocopy`; non-local volume driver/plugin behavior; recursive bind and consistency/cache modes. | Give anonymous volumes a service/one-off-specific identity; do not silently treat `nocopy` as supported. | SELinux relabeling, Windows `npipe`, and Swarm `cluster`/CSI mounts are platform or orchestration specific. |
| Docker API socket | A Docker-compatible socket proxy and credential handoff boundary. | Implement `use_api_socket` only once that boundary exists. | A raw host socket bind is not equivalent to Docker Compose's API socket behavior. |
| Devices and GPUs | Vendor GPU/NVIDIA/CUDA integration, multiple GPUs, device driver options/capabilities, CDI-qualified device selectors, arbitrary hardware passthrough, and verifiable hardware-accelerated rendering. | Map non-GPU Deploy device reservations when a capable runtime primitive exists. | The current single virtio GPU and generic DRM projection are only the supported subset. |
| Logging | Distinct Docker `json-file` and `local` driver semantics plus plugin/remote drivers and their buffering/options. | Map `mode`, `max-buffer-size`, and driver-specific options after the runtime exposes the driver model. | `none`, `json-file`, and `local` are currently accepted, but the latter two use the same logger. |
| Container metadata and state | Distinct OCI/runtime annotations, exposed-port metadata, and full Docker lifecycle state (`created`, `exited`, `dead`, `restarting`, `removing`) rather than the current collapsed status set. | Keep `annotations` distinct from labels; pass `expose`; preserve an explicit empty `command` or `entrypoint` through normalization and runtime argument construction. | Labels, ports, and non-empty command/entrypoint values are already mapped. |
| Events | Full Docker event-action vocabulary: `die`, `destroy`, `kill`, `oom`, `restart`, `rename`, `resize`, `update`, attach/detach, exec, and related attributes. | Render the richer events once the runtime emits them. | Create/start/pause/unpause/stop/delete/health events are available today. |
| Build | A filter-valued no-cache input in the builder/runtime lane. | Preserve and forward `build.no_cache_filter` to live builds and `build --print`; accept all Compose-supported build-secret source forms. | Docker Compose local mode ignores build-secret `uid`, `gid`, and `mode`, so those fields are not a runtime parity gap. |
| Lifecycle hooks | None for `pre_start` or interactive `run` in the pinned fork: it already has volumes-from, network, attach, wait, and log primitives. Stock Apple still lacks the interactive reattach primitive. | Orchestrate Docker Compose `pre_start` helpers; use the pinned reattach primitive for interactive foreground `run` before `post_start`/`pre_stop`. | Docker Compose itself rejects `pre_start.per_replica: true`; it is not a target gap. |
| Deploy and scheduling | Runtime support for any future device/generic resource constraints. | Accept/preserve local-mode Deploy metadata Docker accepts but does not schedule. | Deploy memory reservations now project to the generic soft-memory primitive; Swarm placement, rolling update/rollback timing, and job scheduling are Docker Swarm features, not missing local Compose orchestration. |
| Output templates | None. | Implement Go-template control actions and nested/map object traversal for `ps`, `stats`, and `volumes`. | Flat field references and Docker row-formatting functions are implemented. |
| Models | A model-runner backend that can start models and provide endpoints. | Inject endpoint/model variables after the backend exists. | Parsing and `config` rendering are already supported. |

## Remaining Gap Focus

- `container compose help` is an intentional local extension: the outer `container help compose` command cannot dispatch to a plugin. It is listed in root help, documented in the CLI-surface allowlist, and returns the same Compose-layer help as `container compose --help`.
- Prioritize container-facing DNS, fractional CPU and byte-accurate hard-memory controls, image-volume/copy-up semantics, complete state/events, and Docker logging drivers before expanding platform-only or Swarm-only surfaces.
- When touching slow runtime paths, keep first-frame progress rendering covered so local `container compose` runs do not appear to hang before visible output.
