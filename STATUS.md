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
| Compose project loading and normalization | ✅ Yes | `compose-go` handles multiple files, profiles, interpolation, env files, project name and directory selection, extension preservation, and `config` YAML/JSON output. |
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

`container compose --help` and `container compose COMMAND --help` are the authoritative per-option views. The non-green option set is:

| Option Surface | Parity | Details |
| --- | --- | --- |
| Root options | ⚠️ Partial | ✅ `--ansi`, `--dry-run`, `--env-file`, `--file`, `--profile`, `--progress`, `--project-directory`, `--project-name`, and `--verbose`; ⚠️ `--parallel`; ❌ `--all-resources` and `--compatibility`. `--parallel` currently caps repeated `pull` and `push` image operations; dependency-sensitive orchestration stays ordered. |
| `attach --detach-keys` | ⚠️ Partial | Parsed and documented, but output-only attach ignores detach keys because interactive reattach is not exposed by the runtime. |
| `up --wait` | ⚠️ Partial | Waits for services to be running; health-aware waiting remains blocked by missing runtime health state. |
| `up --wait-timeout` | ⚠️ Partial | Applies to supported waits; health-aware timeout semantics remain blocked by missing runtime health state. |
| `bridge` options | ❌ No | `--dry-run` is not supported because Compose Bridge is not implemented. |
| `bridge convert` options | ❌ No | `--dry-run`, `--output`, `--templates`, and `--transformation` are not supported because Compose Bridge is not implemented. |
| `bridge transformations` options | ❌ No | `--dry-run` is not supported because Compose Bridge is not implemented. |
| `bridge transformations create` options | ❌ No | `--dry-run` and `--from` are not supported because Compose Bridge is not implemented. |
| `bridge transformations list` options | ❌ No | `--dry-run`, `--format`, and `--quiet` are not supported because Compose Bridge is not implemented. |
| `bridge transformations ls` options | ❌ No | `--dry-run`, `--format`, and `--quiet` are not supported because Compose Bridge is not implemented. |
| `commit` options | ❌ No | `--author`, `--change`, `--dry-run`, `--index`, `--message`, and `--pause` are not supported because `commit` is not implemented. |
| `publish` options | ❌ No | `--app`, `--dry-run`, `--oci-version`, `--resolve-image-digests`, `--with-env`, and `--yes` are not supported because `publish` is not implemented. |

## Release Notes

Release notes record the sibling runtime stack through [Tools/release/stack-refs.json](Tools/release/stack-refs.json) so stable releases can highlight user-facing changes from `container`, `containerization`, and `container-builder-shim`, not only commits in this plugin repository.

## Upstream Compatibility

Released Apple `container` compatibility is not a supported-lane functionality gap. The Homebrew preview lane requires the Stephen fork-backed runtime stack and preflights for it before runtime-backed Compose commands run. Stock Apple compatibility remains an upstream/release-channel blocker until equivalent runtime primitives are accepted by Apple and this plugin is updated to consume those upstream APIs.

## Open Follow-ups

- Continue live runtime smoke around progress rendering when touching slow paths. If a local `container compose` run or build appears to hang before any screen output, treat that as a progress regression: reproduce the silent phase, add a focused first-frame test, and emit a Docker Compose-style spinner/status row before the blocking operation begins.

## Next Step

Continue the strict gap scan with `gpus`, arbitrary macOS hardware passthrough, generic service endpoint `driver_opts`, and Deploy device reservations treated as runtime-primitive blockers unless matching Apple-shaped fork primitives are added.
