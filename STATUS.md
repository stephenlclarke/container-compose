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
| Dockerfile and build behavior | ⚠️ Partial | The complete instruction and Build Specification surface is in [Dockerfile And Build Surface](#dockerfile-and-build-surface); build-secret source and metadata shapes remain limited. |
| CLI commands | ✅ Yes | 46 commands are ✅, 0 are ⚠️, and 0 are ❌. Every command is listed in [CLI Command Surface](#cli-command-surface). |
| CLI long options | ✅ Yes | 262 documented long options are ✅, 1 are ⚠️, and 0 are ❌. Every option is listed in [CLI Option Surface](#cli-option-surface). |

## Compose File Surface

The Docker Compose v2 file reference is a rolling Compose Specification surface: top-level project elements, services, networks, volumes, configs, secrets, optional Build/Deploy/Develop specifications, provider/model extensions, fragments, merge behavior, interpolation, profiles, and include behavior. The current parity state is:

| Compose File Surface | Parity | Details |
| --- | --- | --- |
| Project file discovery and sources | ✅ Yes | Default local discovery, explicit and repeated `--file`, `COMPOSE_FILE`, `.env`, `--env-file`, project directory/name, profiles, interpolation controls, path-resolution controls, stdin, Git repository resources, and `oci://` Compose project artifacts are implemented. Git URLs accept Docker's `URL#ref:subdir` syntax, locate canonical Compose filenames in repository directories, resolve relative env/build paths from the checkout, and work in top-level `-f`, `include`, and `extends.file`. OCI project artifacts load Docker Compose project manifests, compose-file layers, env-file layers, OCI 1.0 fallback manifests, OCI 1.1 artifact manifests, image digest override layers, and image-index wrappers. `compose publish` pushes service images and writes OCI project artifacts, image digest override layers, and application image indexes for image-backed projects after Docker-compatible bind-mount, sensitive-data, env-declaration, literal-config, build-only-service, and unresolved-local-include preflights. |
| Top-level `name` and legacy `version` | ✅ Yes | `name` participates in project naming precedence, and legacy `version` is accepted by the Compose Specification loader without driving behavior. |
| Top-level `services` | ⚠️ Partial | Service definitions are parsed and normalized across the current Docker Compose service attribute surface. Runtime-backed gaps are listed in [Service Attribute Surface](#service-attribute-surface), the current-state matrix, and the CLI tables. |
| Top-level `networks` | ⚠️ Partial | `name`, `external`, `internal`, `labels`, top-level `driver_opts`, the default bridge `driver`, and `ipam` with one IPv4 `config.subnet` plus optional IPv4 `gateway` and one IPv6 `config.subnet` are implemented. Custom drivers, `attachable` set true, `enable_ipv4` set false, `enable_ipv6` without a mapped subnet, IPAM `driver`/`options`, IPv6 gateway, `ip_range`/`aux_addresses`, and multiple subnets of the same address family remain runtime gaps and fail before resource creation. |
| Top-level `volumes` | ✅ Yes | `name`, `external`, `driver`, `driver_opts`, and `labels` are implemented through the direct runtime volume API together with Compose project labels. |
| Top-level `configs` | ✅ Yes | `file`, `environment`, inline `content`, and `external` configs are materialized as read-only service mounts with Compose metadata. External config `name` lookup is resolved through the matched `stephenlclarke/container` config store. |
| Top-level `secrets` | ✅ Yes | `file`, `environment`, and `external` secrets are materialized as read-only service mounts and build secrets. External `name` lookup is resolved through the matched `stephenlclarke/container` Keychain-backed secret store. |
| Extensions, fragments, merge, and include | ✅ Yes | YAML anchors/fragments, `x-*` extension fields, interpolation, multi-file merge behavior, and local or Git-backed Compose include/extends handling are delegated to `compose-go`. Include short syntax and long-syntax `path`, `project_directory`, and `env_file` are supported; extension data is preserved in normalized config output. |
| Compose Build Specification | ⚠️ Partial | See [Dockerfile And Build Surface](#dockerfile-and-build-surface) for every build attribute and Dockerfile-adjacent behavior. |
| Compose Deploy Specification | ⚠️ Partial | `mode`, `replicas`, `labels`, `endpoint_mode`, CPU/memory/pids `resources` limits, CPU/memory reservations, generic GPU device reservations, `restart_policy`, both `update_config` `order` values, `rollback_config`, and `placement` are implemented locally or preserved as metadata. Docker Compose local mode recreates services when Deploy metadata changes and does not apply Swarm update timing or parallelism; `container-compose` mirrors that local behavior. Pids reservations, non-GPU device reservations, generic reservations, device/generic limits, and Swarm scheduler or rollback orchestration remain gaps. |
| Compose Develop Specification | ✅ Yes | `develop` `watch` rules support `path`, `action`, `target`, `ignore`, `include`, `initial_sync`, and `exec` metadata for `rebuild`, `restart`, `sync`, `sync+restart`, and `sync+exec`, including prune, `watch --no-up`, `up --watch`, and `up --menu --watch`. |
| Provider services and models | ⚠️ Partial | Provider services run through the Compose provider `type`/`options` protocol and inject provider variables into dependents. Top-level model `model`, `context_size`, and `runtime_flags` plus service model `endpoint_var`/`model_var` are parsed and rendered, but model-runner startup and endpoint injection are rejected until a backend exists. |

## Service Attribute Surface

Docker Compose service attributes are grouped here by runtime behavior so every current service surface has a yes/no/partial indicator without turning this handoff into generated API documentation.

| Service Attribute Surface | Parity | Details |
| --- | --- | --- |
| Identity, image, process, and profile attributes | ✅ Yes | `image`, `platform`, `pull_policy`, `profiles`, `attach`, `container_name`, `hostname`, `domainname`, `command`, `entrypoint`, `working_dir`, `user`, `stdin_open`, `tty`, `init`, `runtime`, and `scale` are parsed and mapped into local orchestration; `extends` is resolved during project loading. |
| Labels, annotations, and extension metadata | ✅ Yes | `labels`, `label_file`, `annotations`, service `x-*` extensions, container names, project labels, and service metadata are preserved or projected where Docker Compose local mode expects them. |
| Environment and env files | ✅ Yes | `environment` and `env_file` short/long syntax are implemented, including optional missing env files and `format: raw` values. Service env files are resolved during normalization like Docker Compose and are not forwarded as runtime `--env-file` arguments. |
| Build-backed services | ⚠️ Partial | `build` string syntax and detailed Build Specification attributes are implemented through the supported Dockerfile/build surface. Build-secret metadata and unsupported secret source shapes remain the only known Build Specification gaps. |
| Dependencies and links | ⚠️ Partial | `depends_on` and `external_links` ordering/discovery are implemented, including `condition: service_completed_successfully`, `condition: service_healthy`, and dependency restart/required metadata where local mode can honor it. Legacy service `links` resolves each linked service's current IPv4 attachment into a source-container static host entry after dependency creation; source and target must share exactly one normalized Compose network, and aliases colliding case-insensitively with source `extra_hosts`, another linked service, or an external link are rejected before side effects. `external_links` likewise resolves a static host entry when its source and external container share exactly one runtime network, even if the source has other attachments. Dynamic source-scoped DNS aliases, direct network `aliases`, legacy or external links with zero or multiple shared networks, address-change propagation outside Compose reconciliation, and richer external-service discovery remain runtime gaps. |
| Ports and exposure | ✅ Yes | `ports` short/long syntax, dynamic host ports, ranges, host IPs, protocols, named/app-protocol metadata, `expose`, and `port` lookup are implemented for local mode. |
| Network attachments and discovery | ⚠️ Partial | `networks`, including multiple attachments at container creation on macOS 26+, `network_mode` values `none` and `host`, service MTU `driver_opts`, `mac_address`, `gw_priority`, connection `priority`, `interface_name`, `ipv4_address`, `ipv6_address`, `link_local_ips`, `dns`, `dns_opt`, `dns_search`, and `extra_hosts` are implemented where the runtime exposes matching primitives. The highest `gw_priority` attachment is made the runtime's first/default-route interface; the highest connection `priority` receives a service-level `mac_address`; `interface_name` assigns a stable guest Linux interface name; `ipv4_address` and `ipv6_address` reserve an address inside the matching Compose-managed IPAM subnet (or are runtime-validated on external networks); and each `link_local_ips` value is configured as an additional guest address using Docker's `/16` IPv4 or `/64` IPv6 mask. Network `aliases` are rejected before side effects because the runtime has no container-facing DNS listener. Arbitrary endpoint `driver_opts`, `network_mode: service:NAME`, and `network_mode: container:NAME` remain runtime gaps. |
| Volumes, mounts, configs, and secrets | ⚠️ Partial | `volumes`, `volumes_from`, `volume_driver`, `tmpfs`, `configs`, and `secrets` are implemented for named, bind, anonymous, tmpfs, file-backed, environment-backed, inline `configs.content`, external-config, and external-secret local mode. Generated config/secret `mode` is honored; generated `uid`/`gid`, mount `consistency`, SELinux, recursive bind, `volume.subpath`, image subpath, `npipe`, `cluster`, and `use_api_socket` remain gaps. |
| Runtime resources and security | ⚠️ Partial | `cpus`, `mem_limit`, `pids_limit`, `pid: host`, `blkio_config`, `sysctls`, `ulimits`, `shm_size`, `privileged`, `cap_add`, `cap_drop`, `read_only`, `restart`, `stop_signal`, and `stop_grace_period` are implemented. `cpu_count`, `cpu_percent`, `cpu_shares`, `cpu_period`, `cpu_quota`, `cpu_rt_runtime`, `cpu_rt_period`, `cpuset`, `mem_reservation`, `memswap_limit`, `mem_swappiness`, `oom_kill_disable`, `oom_score_adj`, `cgroup`, `cgroup_parent`, `ipc`, `isolation`, `group_add`, `security_opt`, `storage_opt`, `userns_mode`, and `uts` are parsed but remain fully or partly limited by runtime primitives; non-host `pid` namespace joins remain unsupported. |
| Devices, GPU, and credentials | ⚠️ Partial | `devices`, `device_cgroup_rules`, service `gpus`, and Deploy generic GPU reservations are implemented through the `stephenlclarke` runtime. GPU requests attach the single Apple virtio-gpu VM device and project Linux DRM character-device metadata when the running guest kernel exposes `/dev/dri`; vendor drivers such as NVIDIA/CUDA, multiple GPUs, driver options, non-GPU device reservations, `credential_spec`, arbitrary macOS hardware passthrough, and verified hardware-accelerated rendering remain runtime gaps. |
| Logging | ⚠️ Partial | `logging.driver` supports `json-file`, `local`, and `none`; `logging.options` supports `max-size` and `max-file`. Other `logging` drivers/options are rejected before side effects. |
| Healthchecks | ✅ Yes | `healthcheck` and Dockerfile `HEALTHCHECK` defaults/overrides are projected into typed runtime configuration. Probe cadence and state, `service_healthy`, health-aware `up/start --wait`, transition events, and `ps` health output are implemented. |
| Lifecycle hooks | ⚠️ Partial | `post_start` and `pre_stop` hooks run for detached and managed lifecycle paths, regular foreground `up`, and non-interactive foreground `run`: Compose starts containers detached, runs `post_start`, then follows output; interruption uses the standard stop path so `pre_stop` runs. Interactive foreground `run` still requires the runtime stdio-reattach primitive, and Docker Compose `pre_start` hook metadata is preserved and explicitly rejected before side effects until the runtime exposes ephemeral init-container lifecycle support. |
| Deploy Specification attributes | ⚠️ Partial | `deploy` fields `mode`, `replicas`, `labels`, `endpoint_mode`, CPU/memory/pids `resources.limits`, CPU/memory `resources.reservations`, generic GPU device reservations, restart policy metadata, both `update_config` `order` values, `rollback_config`, and `placement` are implemented for local behavior or preserved as scheduler metadata. Local update timing and parallelism remain Swarm-only metadata; pids reservations, non-GPU device reservations, generic reservations, device/generic limits, and Swarm scheduler or rollback orchestration semantics remain gaps. |
| Develop Specification attributes | ✅ Yes | `develop` watch rules support `rebuild`, `restart`, `sync`, `sync+restart`, and `sync+exec`, including `path`, `action`, `target`, `ignore`, `include`, `initial_sync`, and `exec` metadata. |
| Provider and model attributes | ⚠️ Partial | `provider` services use `type` and `options`, run through the Compose provider protocol, and inject variables into dependents. Service `models` with `endpoint_var`/`model_var` and top-level `models` with `model`/`context_size`/`runtime_flags` are parsed and rendered by `config`, but runtime model-runner startup and endpoint injection are rejected until a backend exists. |

## Dockerfile And Build Surface

| Dockerfile / Build Surface | Parity | Details |
| --- | --- | --- |
| Dockerfile instruction set and parser directives | ✅ Yes | The `stephenlclarke/container build` BuildKit path supports `syntax`, `escape`, and `check` parser directives, here-documents, shell/exec forms, and the current Dockerfile instructions: `ADD`, `ARG`, `CMD`, `COPY`, `ENTRYPOINT`, `ENV`, `EXPOSE`, `FROM`, `HEALTHCHECK`, `LABEL`, `MAINTAINER`, `ONBUILD`, `RUN`, `SHELL`, `STOPSIGNAL`, `USER`, `VOLUME`, and `WORKDIR`. |
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
| `build.platforms` | ✅ Yes | Target platforms are forwarded to live builds and bake output. |
| `build.privileged` | ✅ Yes | Privileged build mode is forwarded to the `stephenlclarke` builder. |
| `build.provenance` | ✅ Yes | Compose-file and CLI provenance attestations are forwarded, including Docker Compose-compatible false/disabled handling. |
| `build.pull` and `--pull` | ✅ Yes | File and CLI pull controls are applied to live builds and bake output. |
| `build.sbom` | ✅ Yes | Compose-file and CLI SBOM attestations are forwarded, including Docker Compose-compatible false/disabled handling. |
| `build.secrets` | ⚠️ Partial | File-backed and environment-backed BuildKit secret IDs are supported. Secret metadata such as uid/gid/mode is accepted by Compose local mode as metadata but is not projected into BuildKit secret entries; unsupported secret shapes are rejected before side effects. |
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
| `build` | ✅ Yes | Dockerfile/build parity is implemented for the supported build surface above. |
| `commit` | ✅ Yes | Stopped service containers and running containers commit to OCI images through export, archive creation, and image load. The generated image preserves Docker `Healthcheck` metadata and effective Compose healthcheck overrides. The default `--pause=true` running path briefly freezes the root filesystem; `--pause=false` uses the generic best-effort APFS copy-on-write snapshot in the pinned `stephenlclarke/container` fork and leaves the filesystem writable. Omitted `--index` and `--index=0` use Docker Compose's default service-container selection. |
| `config` | ✅ Yes | Compose project rendering and config query options are implemented. |
| `convert` | ✅ Yes | Docker Compose's config-compatible model conversion projections are implemented for the documented local output modes. |
| `cp` | ✅ Yes | Local-to-service, service-to-local, service-to-service, stdin tar archive, and stdout tar archive copies are implemented, including archive, follow-link, replica-index, and one-off-container modes. |
| `create` | ✅ Yes | Service creation, build/pull/recreate controls, scaling, and orphan handling are implemented. |
| `down` | ✅ Yes | Container, network, image, volume, timeout, orphan, and service-scoped cleanup are implemented. |
| `events` | ✅ Yes | Event output, JSON mode, and time filters are implemented. |
| `exec` | ✅ Yes | Service exec options, indexes, env, user, workdir, tty, detach, and privileged mode are implemented. |
| `export` | ✅ Yes | Container filesystem export to an archive path is implemented for stopped containers and automatically uses the generic live snapshot path for running service containers. |
| `help` | ✅ Yes | Docker Compose-compatible help rendering and support colors are implemented. |
| `images` | ✅ Yes | Image listing and formatting are implemented. |
| `kill` | ✅ Yes | Signal and orphan handling are implemented. |
| `logs` | ✅ Yes | Follow, timestamps, prefix/color controls, indexes, tail, and time filters are implemented. |
| `ls` | ✅ Yes | Project listing, filters, formats, quiet, and all modes are implemented. |
| `pause` | ✅ Yes | Service pause is implemented. |
| `port` | ✅ Yes | Published-port lookup by service, index, and protocol is implemented. |
| `ps` | ✅ Yes | Container listing, filters, statuses, service selection, formats, and quiet/services output are implemented. |
| `publish` | ✅ Yes | Service image push, OCI project artifact publishing, image digest override layers, and `--app` application image indexes are implemented for image-backed Compose projects. Supported publish behavior includes all-profile image selection, `--dry-run`, `--app`, `--oci-version`, `--resolve-image-digests`, `--with-env`, Docker-compatible interactive preflight prompts, and noninteractive `--yes` prompt acceptance. |
| `pull` | ✅ Yes | Pull policy, dependency inclusion, quiet mode, and ignore-failure behavior are implemented. |
| `push` | ✅ Yes | Dependency inclusion, quiet mode, and ignore-failure behavior are implemented. |
| `restart` | ✅ Yes | Service restart, dependency control, and timeout are implemented. |
| `rm` | ✅ Yes | Stopped-container removal, force, stop, and volume cleanup are implemented. |
| `run` | ✅ Yes | One-off containers and Docker Compose run options are implemented. |
| `scale` | ✅ Yes | Service scaling and dependency control are implemented. |
| `start` | ✅ Yes | Start, health-aware wait, and wait-timeout behavior are implemented. |
| `stats` | ✅ Yes | Table/JSON formatting, stopped-container inclusion, no-stream, and no-trunc modes are implemented. |
| `stop` | ✅ Yes | Stop and timeout are implemented. |
| `top` | ✅ Yes | Service selection and Docker-shaped per-container process tables are implemented through the matched runtime process-metadata API, including UID, PID, PPID, CPU, STIME, TTY, TIME, and CMD columns. |
| `unpause` | ✅ Yes | Service unpause is implemented. |
| `up` | ✅ Yes | Create/start/attach/watch/menu/build/pull/recreate/exit-control/log-output/scaling behavior and health-aware `--wait`/`--wait-timeout` are implemented. |
| `version` | ✅ Yes | Pretty, short, and JSON version output are implemented. |
| `volumes` | ✅ Yes | Volume listing, quiet, and formatting are implemented. |
| `wait` | ✅ Yes | Container exit waiting and `--down-project` cleanup are implemented. |
| `watch` | ✅ Yes | Develop watch actions and options are implemented. |

## CLI Option Surface

`container compose --help` and `container compose COMMAND --help` are the authoritative usage views. Every documented long option surface is listed here with per-option parity markers.

A ✅ option means the flag itself is parsed and mapped for the current command behavior. Command parity is still a separate axis; command rows above describe any remaining operand or runtime limitations that are not represented as long options.

| Option Surface | Parity | Details |
| --- | --- | --- |
| Root options | ✅ Yes | ✅ `--all-resources`: selected-service `config` and `convert` output keeps unreferenced top-level networks, volumes, configs, and secrets, ✅ `--ansi`, ✅ `--compatibility`: uses Docker Compose legacy underscore separators for generated service and one-off container names, ✅ `--dry-run`, ✅ `--env-file`, ✅ `--file`, ✅ `--parallel` and `COMPOSE_PARALLEL_LIMIT`: limit independent pull, push, and build engine operations, with `-1` as the unlimited default; dependency-sensitive lifecycle orchestration remains ordered, ✅ `--profile`, ✅ `--progress`, ✅ `--project-directory`, ✅ `--project-name`, ✅ `--verbose`. |
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
| `exec` options | ✅ Yes | ✅ `--detach`, ✅ `--dry-run`, ✅ `--env`, ✅ `--index`, ✅ `--no-tty`, ✅ `--privileged`, ✅ `--user`, ✅ `--workdir`. |
| `export` options | ✅ Yes | ✅ `--dry-run`, ✅ `--index`, ✅ `--output`. |
| `images` options | ✅ Yes | ✅ `--dry-run`, ✅ `--format`, ✅ `--quiet`. |
| `kill` options | ✅ Yes | ✅ `--dry-run`, ✅ `--remove-orphans`, ✅ `--signal`. |
| `logs` options | ✅ Yes | ✅ `--dry-run`, ✅ `--follow`, ✅ `--index`, ✅ `--no-color`, ✅ `--no-log-prefix`, ✅ `--since`, ✅ `--tail`, ✅ `--timestamps`, ✅ `--until`. |
| `ls` options | ✅ Yes | ✅ `--all`, ✅ `--dry-run`, ✅ `--filter`, ✅ `--format`, ✅ `--quiet`. |
| `pause` options | ✅ Yes | ✅ `--dry-run`. |
| `port` options | ✅ Yes | ✅ `--dry-run`, ✅ `--index`, ✅ `--protocol`. |
| `ps` options | ✅ Yes | ✅ `--all`, ✅ `--dry-run`, ✅ `--filter`, ✅ `--format`, ✅ `--no-trunc`, ✅ `--orphans`, ✅ `--quiet`, ✅ `--services`, ✅ `--status`. |
| `publish` options | ✅ Yes | ✅ `--app`: publish an application image index linked to the Compose project artifact, ✅ `--dry-run`, ✅ `--oci-version`, ✅ `--resolve-image-digests`, ✅ `--with-env`, ✅ `--yes`. |
| `pull` options | ✅ Yes | ✅ `--dry-run`, ✅ `--ignore-buildable`, ✅ `--ignore-pull-failures`, ✅ `--include-deps`, ✅ `--policy`, ✅ `--quiet`. |
| `push` options | ✅ Yes | ✅ `--dry-run`, ✅ `--ignore-push-failures`, ✅ `--include-deps`, ✅ `--quiet`. |
| `restart` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-deps`, ✅ `--timeout`. |
| `rm` options | ✅ Yes | ✅ `--dry-run`, ✅ `--force`, ✅ `--stop`, ✅ `--volumes`. |
| `run` options | ⚠️ Partial | ✅ `--build`, ✅ `--cap-add`, ✅ `--cap-drop`, ✅ `--detach`, ✅ `--dry-run`, ✅ `--entrypoint`, ✅ `--env`, ✅ `--env-from-file`, ✅ `--interactive`, ✅ `--label`, ✅ `--name`, ✅ `--no-tty`, ✅ `--no-deps`, ✅ `--publish`, ✅ `--pull`, ✅ `--quiet`, ✅ `--quiet-build`, ✅ `--quiet-pull`, ✅ `--remove-orphans`, ✅ `--rm`, ✅ `--service-ports`, ⚠️ `--use-aliases` (requires container-facing DNS), ✅ `--user`, ✅ `--volume`, ✅ `--workdir`. |
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

## Upstream Compatibility

Released Apple `container` compatibility is not a supported-lane functionality gap. The Homebrew release lane requires the matched `stephenlclarke` runtime stack and preflights for it before runtime-backed Compose commands run. Stock Apple compatibility remains an upstream/release-channel blocker until equivalent runtime primitives are accepted by Apple and this plugin is updated to consume those upstream APIs.

## Remaining Gap Focus

- All documented CLI commands are green. The `run --use-aliases` long option remains partial pending container-facing DNS support.
- Runtime-primitive blockers include vendor/native GPU passthrough, multiple GPUs, arbitrary macOS hardware passthrough, generic service endpoint `driver_opts`, and non-GPU Deploy device/generic reservations.
- When touching slow runtime paths, keep first-frame progress rendering covered so local `container compose` runs do not appear to hang before visible output.
