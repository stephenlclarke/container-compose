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

- `container-compose`: `make check`, `make cli-smoke-built`, targeted Swift help tests when the CLI support matrix changes, markdownlint for touched docs, and release asset/tap checksum verification during release.
- `container`: `make check`, `make test`, targeted lifecycle integration tests, and full `make integration` when runtime behavior changes.

Stable package workflows publish `container-compose-plugin-release-arm64.tar.gz`, verify the release asset checksum, and update the Homebrew tap after artifacts are ready. The source formula records the current stable release URL, version, and checksum.

## Parity Legend

- ✅ Yes: Docker Compose v2 parity is implemented for the current Stephen fork-backed runtime lane.
- ⚠️ Partial: a Docker Compose-compatible subset is implemented; details list the remaining gap.
- ❌ No: the surface is intentionally rejected before side effects or has no implementation.

Runtime-backed commands preflight the installed stack before work begins. Apple stock or mismatched Homebrew installs fail with [INSTALL.md](INSTALL.md) guidance instead of a late unsupported-feature or runtime error.

## Compose Surface Matrix

| Surface | Parity | Details |
| --- | --- | --- |
| Compose project loading and normalization | ⚠️ Partial | `compose-go` handles local/default files, multiple files, profiles, interpolation, env files, project name and directory selection, extension preservation, and `config` YAML/JSON output. Docker Compose remote `-f` sources such as `oci://` artifacts and Git repository URLs are not implemented. |
| CLI command surface | ⚠️ Partial | 31 commands are ✅, 2 are ⚠️, and 8 are ❌. See [CLI Command Surface](#cli-command-surface). |
| CLI option surface | ⚠️ Partial | 211 documented long options are ✅, 4 are ⚠️, and 28 are ❌. See [CLI Option Surface](#cli-option-surface). |
| Dockerfile and build inputs | ⚠️ Partial | Contexts, `dockerfile`, `dockerfile_inline`, `.dockerignore`, args, additional contexts, cache hints, labels, target, platforms, pull/no-cache, tags, `extra_hosts`, BuildKit network, isolation, privileged build, shm size, ulimits, SSH forwarding, provenance, SBOM, builder selection, `--print`, and `--check` are implemented. Build secrets are limited to file/env-backed BuildKit secret IDs; unsupported secret shapes are rejected. |
| Image pull, push, and local image metadata | ✅ Yes | `pull`, `push`, `images`, image digest config output, pull policy, quiet modes, failure-ignore modes, and dependency image traversal are implemented. |
| Service lifecycle orchestration | ⚠️ Partial | `create`, `start`, `stop`, `restart`, `kill`, `pause`, `unpause`, `rm`, `down`, `scale`, `wait`, and most `up` behavior are implemented. Health-aware `up --wait`, health dependency state, and completion metadata remain runtime gaps. |
| Process execution and attach | ⚠️ Partial | `run` and `exec` are implemented, including env, user, workdir, entrypoint, labels, caps, ports, volumes, service ports, aliases, and privileged mode. `attach --no-stdin` is implemented; interactive stdin/stdout/stderr reattach and detach-key handling remain runtime gaps. |
| Logs, events, stats, top, and ps | ⚠️ Partial | `logs`, `events`, `stats`, `top`, `ps`, `ls`, and `port` are implemented. Logging drivers are limited to `json-file`, `local`, and `none`; log options are limited to `max-size` and `max-file`. |
| Ports and service discovery | ✅ Yes | Short and long published ports, dynamic port allocation, host address/protocol matching, `expose`, `port`, `links`, `external_links`, and single-network aliases are implemented. |
| Networks and IPAM | ⚠️ Partial | Project networks, `internal`, driver metadata, top-level `driver_opts`, one IPv4 subnet, one IPv6 subnet, host/no-network modes, service MTU driver option, and single-network MAC/alias attachment are implemented. IPAM driver/options/gateway/ranges/aux addresses, multiple subnets of one family, arbitrary endpoint driver options, and multi-network aliases remain runtime gaps. |
| Volumes, mounts, configs, and secrets | ⚠️ Partial | Named, bind, anonymous, tmpfs, `volumes_from`, bind `create_host_path`, bind propagation, file/env-backed configs and secrets, and service mount labels are implemented. Mount `consistency`, SELinux, recursive bind, `volume.subpath`, image subpath, unsupported mount types, API socket handoff, and nested bind mount overlay behavior remain gaps. |
| Runtime resources and security options | ⚠️ Partial | `cpus`, `mem_limit`, `pids_limit`, blkio controls, `sysctls`, `ulimits`, `shm_size`, `privileged`, `cap_add`, `cap_drop`, `read_only`, `init`, restart policy, stop signal/grace period, hostname/domainname, DNS options, and extra hosts are implemented. Advanced CPU scheduler fields, memory reservation/swap/swappiness/OOM controls, cgroup fields, IPC, isolation, user namespace, UTS, supplemental groups, and `security_opt` remain runtime gaps. |
| Devices and GPU | ⚠️ Partial | `device_cgroup_rules` and Linux VM `devices` mappings are implemented through the fork-backed runtime. `gpus`, credential specs, arbitrary macOS hardware passthrough, and Deploy device reservations remain runtime gaps. |
| Namespace modes | ⚠️ Partial | `network_mode: none`, `network_mode: host`, and `pid: host` are implemented. `network_mode: service:NAME`, `network_mode: container:NAME`, `pid: service:NAME`, and `pid: container:NAME` need Docker-compatible namespace-join primitives. |
| Healthchecks and dependency conditions | ⚠️ Partial | Healthcheck config is parsed and image healthcheck overrides are validated. Runtime health execution/state is not available, so `service_healthy`, full health-aware `up --wait`, and health status display remain blocked by [apple/container#1918](https://github.com/apple/container/issues/1918). |
| Deploy specification | ⚠️ Partial | Replicas, local job modes, stop-first update delay, restart policy metadata, deploy labels, CPU/memory local limits, CPU/memory reservation metadata, and `endpoint_mode` metadata are implemented. Start-first updates, scheduler placement behavior, pids/device/generic reservations, pids/device/generic limits, and remaining Swarm scheduler semantics remain gaps. |
| Develop specification and watch | ✅ Yes | `develop.watch` supports `rebuild`, `restart`, `sync`, `sync+restart`, and `sync+exec`, including include/ignore filters, initial sync, prune, `watch --no-up`, `up --watch`, and `up --menu --watch`. |
| Provider and model services | ⚠️ Partial | Provider services run through the Compose provider protocol and inject provider variables into dependent services. Compose model bindings are rejected until a model-runner backend and endpoint injection primitive exist. |
| Labels, annotations, and metadata | ✅ Yes | Service labels, label files, annotations, container names, project/resource labels, deploy labels, top-level volumes/configs/secrets metadata, and Compose extension fields are preserved or mapped where Docker Compose local mode expects them. |

## Compose File Surface

The Docker Compose v2 file reference is a rolling Compose Specification surface: top-level project elements, services, networks, volumes, configs, secrets, optional Build/Deploy/Develop specifications, provider/model extensions, fragments, merge behavior, and include behavior. The current parity state is:

| Compose File Surface | Parity | Details |
| --- | --- | --- |
| Project file discovery and sources | ⚠️ Partial | Default local file discovery, explicit local `--file`, repeated files, `COMPOSE_FILE`, `.env`, `--env-file`, project directory, project name, profiles, interpolation controls, path-resolution controls, and stdin-style local loader paths are handled by `compose-go`. Docker Compose remote `-f` sources such as `oci://` artifacts and Git repository URLs are not implemented. |
| Top-level `name` and legacy `version` | ✅ Yes | `name` participates in project naming precedence, and legacy `version` is accepted by the Compose Specification loader without driving behavior. |
| Top-level `services` | ⚠️ Partial | Service definitions, dependencies, images, build, commands, environment, ports, networks, volumes, configs, secrets, resources, lifecycle hooks, healthchecks, labels, annotations, and local mode metadata are parsed. Runtime-backed service gaps are listed in the current-state and CLI tables. |
| Top-level `networks` | ⚠️ Partial | Project networks, explicit names, external names, `internal`, driver metadata, top-level `driver_opts`, and one IPv4 plus one IPv6 IPAM subnet are implemented. IPAM driver/options/gateway/ranges/aux addresses and multiple subnets of the same address family remain runtime gaps. |
| Top-level `volumes` | ✅ Yes | Named volumes, explicit names, external volumes, local driver metadata, driver options, labels, and project labels are implemented through the direct runtime API. |
| Top-level `configs` | ⚠️ Partial | File-backed and environment-backed configs are materialized as read-only service mounts with Compose metadata. External configs and non-file/non-env config backends remain runtime gaps. |
| Top-level `secrets` | ⚠️ Partial | File-backed and environment-backed secrets are materialized as read-only service mounts and build secrets. External secrets and non-file/non-env secret backends remain runtime gaps. |
| Extensions, fragments, merge, and include | ✅ Yes | YAML anchors/fragments, `x-*` extension fields, multi-file merge behavior, and Compose include handling are delegated to `compose-go`; extension data is preserved in normalized config output. |
| Compose Build Specification | ⚠️ Partial | See [Dockerfile And Build Surface](#dockerfile-and-build-surface) for every build attribute and Dockerfile-adjacent behavior. |
| Compose Deploy Specification | ⚠️ Partial | Replicas, local job modes, stop-first update delay, restart policy metadata, labels, CPU/memory local limits, CPU/memory reservation metadata, and `endpoint_mode` metadata are implemented. Start-first updates, scheduler placement behavior, pids/device/generic reservations, pids/device/generic limits, and Swarm scheduler behavior remain gaps. |
| Compose Develop Specification | ✅ Yes | `develop.watch` supports `rebuild`, `restart`, `sync`, `sync+restart`, and `sync+exec`, including include/ignore filters, initial sync, prune, `watch --no-up`, `up --watch`, and `up --menu --watch`. |
| Provider services and models | ⚠️ Partial | Provider services run through the Compose provider protocol and inject provider variables into dependents. Compose model bindings are rejected until a model-runner backend and endpoint injection primitive exist. |

## Dockerfile And Build Surface

| Dockerfile / Build Surface | Parity | Details |
| --- | --- | --- |
| Dockerfile instruction execution | ✅ Yes | Service builds run through the fork-backed `container build` BuildKit path, so Dockerfile instruction parsing and execution follow the supported BuildKit backend. |
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
| Dockerfile `HEALTHCHECK` inheritance | ⚠️ Partial | Dockerfile healthcheck metadata is inherited through the fork-backed image metadata API when available, and explicit Compose timing overrides merge with image defaults. Runtime health execution/state, `service_healthy`, full health-aware `up --wait`, and health status display remain blocked by missing runtime health state. |

## CLI Command Surface

| Command | Parity | Details |
| --- | --- | --- |
| `attach` | ⚠️ Partial | `--no-stdin` output-follow attach is implemented; default interactive reattach and detach-key handling need runtime support. |
| `bridge` | ❌ No | Compose Bridge transformation tooling is not implemented. |
| `bridge convert` | ❌ No | Compose Bridge transformation tooling is not implemented. |
| `bridge transformations` | ❌ No | Compose Bridge transformation tooling is not implemented. |
| `bridge transformations create` | ❌ No | Compose Bridge transformation tooling is not implemented. |
| `bridge transformations list` | ❌ No | Compose Bridge transformation tooling is not implemented. |
| `bridge transformations ls` | ❌ No | Compose Bridge transformation tooling is not implemented. |
| `build` | ✅ Yes | Dockerfile/build parity is implemented for the supported build surface above. |
| `commit` | ❌ No | Container commit/image mutation is not implemented. |
| `config` | ✅ Yes | Compose project rendering and config query options are implemented. |
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
| `start` | ✅ Yes | Start, wait, and wait-timeout are implemented for running-state waits. |
| `stats` | ✅ Yes | Table/JSON formatting, stopped-container inclusion, no-stream, and no-trunc modes are implemented. |
| `stop` | ✅ Yes | Stop and timeout are implemented. |
| `top` | ✅ Yes | Process listing is implemented. |
| `unpause` | ✅ Yes | Service unpause is implemented. |
| `up` | ⚠️ Partial | Create/start/attach/watch/menu/build/pull/recreate/exit-control/log-output/scaling behavior is implemented; health-aware `--wait` and `--wait-timeout` remain partial until runtime health state exists. |
| `version` | ✅ Yes | Pretty, short, and JSON version output are implemented. |
| `volumes` | ✅ Yes | Volume listing, quiet, and formatting are implemented. |
| `wait` | ✅ Yes | Container exit waiting and `--down-project` cleanup are implemented. |
| `watch` | ✅ Yes | Develop watch actions and options are implemented. |

## CLI Option Surface

`container compose --help` and `container compose COMMAND --help` are the authoritative usage views. Every documented long option surface is listed here with per-option parity markers.

| Option Surface | Parity | Details |
| --- | --- | --- |
| Root options | ⚠️ Partial | ✅ `--ansi`, ✅ `--dry-run`, ✅ `--env-file`, ✅ `--file`, ✅ `--profile`, ✅ `--progress`, ✅ `--project-directory`, ✅ `--project-name`, ✅ `--verbose`; ⚠️ `--parallel`: caps repeated `pull` and `push` image operations while dependency-sensitive orchestration stays ordered; ❌ `--all-resources`, ❌ `--compatibility`: unsupported root modes. |
| `attach` options | ⚠️ Partial | ✅ `--dry-run`, ✅ `--index`, ✅ `--no-stdin`, ✅ `--sig-proxy`; ⚠️ `--detach-keys`: parsed and documented, but output-only attach ignores detach keys because interactive reattach is not exposed by the runtime. |
| `bridge` options | ❌ No | ❌ `--dry-run`: Compose Bridge is not implemented. |
| `bridge convert` options | ❌ No | ❌ `--dry-run`, ❌ `--output`, ❌ `--templates`, ❌ `--transformation`: Compose Bridge is not implemented. |
| `bridge transformations` options | ❌ No | ❌ `--dry-run`: Compose Bridge is not implemented. |
| `bridge transformations create` options | ❌ No | ❌ `--dry-run`, ❌ `--from`: Compose Bridge is not implemented. |
| `bridge transformations list` options | ❌ No | ❌ `--dry-run`, ❌ `--format`, ❌ `--quiet`: Compose Bridge is not implemented. |
| `bridge transformations ls` options | ❌ No | ❌ `--dry-run`, ❌ `--format`, ❌ `--quiet`: Compose Bridge is not implemented. |
| `build` options | ✅ Yes | ✅ `--build-arg`, ✅ `--builder`, ✅ `--check`, ✅ `--dry-run`, ✅ `--memory`, ✅ `--no-cache`, ✅ `--print`, ✅ `--provenance`, ✅ `--pull`, ✅ `--push`, ✅ `--quiet`, ✅ `--sbom`, ✅ `--ssh`, ✅ `--with-dependencies`. |
| `commit` options | ❌ No | ❌ `--author`, ❌ `--change`, ❌ `--dry-run`, ❌ `--index`, ❌ `--message`, ❌ `--pause`: `commit` is not implemented. |
| `config` options | ✅ Yes | ✅ `--dry-run`, ✅ `--environment`, ✅ `--format`, ✅ `--hash`, ✅ `--images`, ✅ `--lock-image-digests`, ✅ `--models`, ✅ `--networks`, ✅ `--no-consistency`, ✅ `--no-env-resolution`, ✅ `--no-interpolate`, ✅ `--no-normalize`, ✅ `--no-path-resolution`, ✅ `--output`, ✅ `--profiles`, ✅ `--quiet`, ✅ `--resolve-image-digests`, ✅ `--services`, ✅ `--variables`, ✅ `--volumes`. |
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
| `run` options | ✅ Yes | ✅ `--build`, ✅ `--cap-add`, ✅ `--cap-drop`, ✅ `--detach`, ✅ `--dry-run`, ✅ `--entrypoint`, ✅ `--env`, ✅ `--env-from-file`, ✅ `--interactive`, ✅ `--label`, ✅ `--name`, ✅ `--no-TTY`, ✅ `--no-deps`, ✅ `--publish`, ✅ `--pull`, ✅ `--quiet`, ✅ `--quiet-build`, ✅ `--quiet-pull`, ✅ `--remove-orphans`, ✅ `--rm`, ✅ `--service-ports`, ✅ `--use-aliases`, ✅ `--user`, ✅ `--volume`, ✅ `--workdir`. |
| `scale` options | ✅ Yes | ✅ `--dry-run`, ✅ `--no-deps`. |
| `start` options | ✅ Yes | ✅ `--dry-run`, ✅ `--wait`, ✅ `--wait-timeout`. |
| `stats` options | ✅ Yes | ✅ `--all`, ✅ `--dry-run`, ✅ `--format`, ✅ `--no-stream`, ✅ `--no-trunc`. |
| `stop` options | ✅ Yes | ✅ `--dry-run`, ✅ `--timeout`. |
| `top` options | ✅ Yes | ✅ `--dry-run`. |
| `unpause` options | ✅ Yes | ✅ `--dry-run`. |
| `up` options | ⚠️ Partial | ✅ `--abort-on-container-exit`, ✅ `--abort-on-container-failure`, ✅ `--always-recreate-deps`, ✅ `--attach`, ✅ `--attach-dependencies`, ✅ `--build`, ✅ `--detach`, ✅ `--dry-run`, ✅ `--exit-code-from`, ✅ `--force-recreate`, ✅ `--menu`, ✅ `--no-attach`, ✅ `--no-build`, ✅ `--no-color`, ✅ `--no-deps`, ✅ `--no-log-prefix`, ✅ `--no-recreate`, ✅ `--no-start`, ✅ `--pull`, ✅ `--quiet-build`, ✅ `--quiet-pull`, ✅ `--remove-orphans`, ✅ `--renew-anon-volumes`, ✅ `--scale`, ✅ `--timeout`, ✅ `--timestamps`, ✅ `--watch`, ✅ `--yes`; ⚠️ `--wait`, ⚠️ `--wait-timeout`: running-state waits work, but health-aware wait semantics need runtime health state. |
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
