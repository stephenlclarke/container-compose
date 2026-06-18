# Compatibility

`container-compose` targets local-development Docker Compose v2 workflows where [`apple/container`][apple-container] exposes matching runtime primitives.

This file separates three different questions that are easy to blur together:

- Does Docker Compose v2 accept and normalize the Compose file?
- Does [`apple/container`][apple-container] expose the runtime primitive needed to run it?
- Does [`stephenlclarke/container-compose`](https://github.com/stephenlclarke/container-compose) map that normalized model to [`apple/container`][apple-container] APIs or commands?

Unsupported runtime features are rejected before resources are created. Harmless metadata can still appear in `container compose config` or `container compose convert` without implying that `container compose up` applies runtime behavior.

## How To Read This File

Read every row as a three-step chain:

1. Docker Compose v2 accepts and normalizes the Compose file.
2. [`apple/container`][apple-container] has a runtime primitive that can perform the behavior.
3. `container-compose` maps the normalized Compose model to [`apple/container`][apple-container] APIs or commands.

The first unsupported step owns the gap.

| Bucket | Docker Compose v2 | [`apple/container`][apple-container] | `container-compose` | What happens today | Fix owner |
| --- | --- | --- | --- | --- | --- |
| Supported | Accepts the surface | Has a matching primitive | Maps it | Runtime work executes through [`apple/container`][apple-container] APIs or CLI commands | No compatibility fix needed |
| [`apple/container`][apple-container] gap | Accepts the surface | Missing, incomplete, or not exposed | Detects the field and rejects it | Fails before resources are created with an `apple/container` runtime gap message | Upstream [`apple/container`][apple-container], then this repo maps the new primitive |
| `container-compose` gap | Accepts the surface | Not known to be the first blocker | Does not map it yet | Fails before resources are created with a `container-compose` implementation message | This repository |
| Config-only | Accepts the surface | Not needed for `config` output | Preserves it for `config` | Appears in normalized output; runtime commands ignore harmless metadata or reject service-level use | Depends on the runtime behavior requested later |

## Support Matrix

### Supported By apple/container And container-compose

These surfaces have all three pieces: Docker Compose v2 model support, [`apple/container`][apple-container] runtime support, and plugin orchestration.

| Compose v2 surface | Supported subset | [`apple/container`][apple-container] primitive used | Example |
| --- | --- | --- | --- |
| Config normalization | File discovery, repeated `-f`, `.env`, `--env-file`, interpolation, merge, profiles, `--project-directory`, `-p/--project-name`, and canonical `config`/`convert` JSON | No runtime primitive; `compose-go` normalizes the Compose model | [S1](#s1-supported-local-web-stack), [O1](#o1-config-only-metadata) |
| Build and images | `build.context`, `build.dockerfile`, `build.dockerfile_inline`, `build.args`, `build.cache_from`, `build.cache_to`, `build.labels`, `build.platforms`, `build.target`, `build.no_cache`, `build.pull`, `build.tags`, file-backed and environment-backed `build.secrets`, CLI `build --no-cache`, `build --pull`, `build --push` for explicit service images, `build --quiet/-q`, `build --with-dependencies`, `pull`, `pull --include-deps`, `pull --ignore-buildable`, `pull --ignore-pull-failures`, `pull --policy always/missing`, `pull --quiet/-q`, `push`, `push --include-deps`, `push --ignore-push-failures`, `push --quiet/-q`, runtime-scoped `images`, `images --format table/json`, `images --quiet/-q`, global `up --pull always/missing/if_not_present/never`, `up --no-build`, `up --quiet-build`, `up --quiet-pull`, `create --pull always/missing/if_not_present/never/build`, `create --build`, `create --no-build`, `create --quiet-pull`, one-off `run --pull always/missing/if_not_present/never`, service `pull_policy: always/missing/if_not_present/never/build/daily/weekly/every_<duration>`, image removal through `down --rmi local/all` | `container build --pull --quiet --platform --cache-in --cache-out --tag --label --secret --file`, temporary Dockerfile materialization for `build.dockerfile_inline`, `container image pull --progress none` for dry-run quiet-pull plans, `ClientImage.pull(reference:platform:scheme:containerSystemConfig:progressUpdate:maxConcurrentDownloads:)`, `ClientImage.get(names:containerSystemConfig:)`, container-compose pull timestamp metadata for time-window service policies, `ClientImage.push(platform:scheme:containerSystemConfig:progressUpdate:)`, `ClientImage.delete(reference:garbageCollect:)`, `ClientImage.cleanUpOrphanedBlobs()`, `ContainerClient.list(filters:)` | [S1](#s1-supported-local-web-stack) |
| Container lifecycle | `create`, `up`, `up --no-start`, `up --always-recreate-deps`, `up --timeout`, `up --scale`, `create --scale`, standalone `scale`, `scale --no-deps`, service `scale`, local `deploy.replicas`, service `attach: false` for `up` foreground selection, `down`, `run`, `start`, `stop`, `restart`, `rm`, `rm --force/-f`, `kill`, `wait` for running/stopping service containers, `wait --down-project` for running/stopping service containers, deterministic names, indexed replica names, one-off names, config-hash recreate, `--force-recreate`, `--no-recreate`, `--remove-orphans`, `down --rmi local/all`, `up/stop/restart/down --timeout`, one-off `run --rm`, one-off `run --detach/-d`, one-off `run --name` | `container create`, `container run`, `container run --detach`, `ContainerClient.bootstrap(id:stdio:dynamicEnv:)`, `ClientProcess.start()`, `ClientProcess.wait()`, `ContainerClient.get(id:)`, `ContainerClient.list(filters:)`, `ContainerClient.stop(id:opts:)`, `ContainerClient.delete(id:force:)`, `ContainerClient.kill(id:signal:)` | [S1](#s1-supported-local-web-stack) |
| Project discovery | `ls`, `ls --all/-a`, `ls --format table/json`, `ls --quiet/-q`, and `ls --filter name=...` from project labels on created containers | `ContainerClient.list(filters:)` and Compose project/config-hash labels | [S1](#s1-supported-local-web-stack) |
| Container interaction | `ps`, `ps --quiet`, `ps --services`, `ps --status running/exited`, `ps --filter status=...`, `logs`, `logs --index N` for existing Compose-managed service containers, harmless `logs --no-color` and `logs --no-log-prefix`, output-only `attach --no-stdin --sig-proxy=false`, `attach --index N` for existing Compose-managed service containers, `exec` with Compose-default stdin/TTY, `exec -T/--no-tty`, `exec --interactive=false`, `exec --detach/-d`, `exec --env/-e`, `exec --user/-u`, `exec --workdir/-w`, `exec --index N` for existing Compose-managed service containers, service-aware `cp`, service-to-service `cp`, `cp --index N` for existing Compose-managed service containers, local/service `cp --all` including one-off `run` containers, service-to-service `cp --all` into every resolved destination container, `export`, `export -o/--output`, `export --index N` for existing Compose-managed service containers, `port` for explicit published bindings including explicit ranges and indexed existing service containers, `stats [SERVICE...]`, `stats --all`, `stats --format table/json`, `stats --no-stream`, `version`, `version --short`, `version -f/--format pretty/json` | `ContainerClient.list(filters:)` for indexed service-container lookup, `ContainerClient.get(id:)` projected `publishedPorts`, `ContainerClient.logs(id:)`, raw monochrome prefix-free log emission for `logs --no-color` and `logs --no-log-prefix`, `ProcessIO.create(tty:interactive:detach:)`, `ContainerClient.createProcess(containerId:processId:configuration:stdio:)`, `ProcessIO.handleProcess(process:log:)` for attached exec, `ClientProcess.start()` for detached exec with `--env`, `--user`, and `--workdir`, `ContainerClient.copyIn(id:source:destination:)`, `ContainerClient.copyOut(id:source:destination:)`, staged service-to-service copies through `copyOut` then `copyIn`, `ContainerClient.list(filters:)` for one-off copy target discovery, `ContainerClient.export(id:archive:)`, `ContainerClient.stats(id:)`, stopped-container metadata from `ContainerClient.list(filters:)`, plugin version output | [S1](#s1-supported-local-web-stack) |
| Default networking | One service network, default project networks, external networks, service `network_mode: none`, project network `internal`, one IPv4 and one IPv6 project network IPAM `subnet`, explicit host-published service ports for `create` and `up`, scaled published-port ranges with enough explicit host ports for every replica, single-network service or per-network `mac_address`, single-network MTU via service network `driver_opts.com.docker.network.driver.mtu`, one-off `run --service-ports/-P` with explicit host ports, one-off `run --publish/-p` with explicit host ports | `NetworkClient.create(configuration:)`, `NetworkConfiguration(mode:ipv4Subnet:ipv6Subnet:)`, `NetworkClient.delete(id:)`, `container network create --internal --subnet --subnet-v6`, `container create --network none`, `container create --network <name>[,mac=...,mtu=...]`, `container create --publish`, `container run --network none`, `container run --network <name>[,mac=...,mtu=...]`, `container run --publish`, deterministic per-replica published-port range allocation | [S1](#s1-supported-local-web-stack) |
| Default storage | Named volumes, top-level volume `driver`, top-level volume `driver_opts`, top-level volume `labels`, external volumes, bind mounts, anonymous volumes, read-only mounts, tmpfs mounts including long-form `tmpfs.size` and `tmpfs.mode`, same-project service `volumes_from` for declared Compose mounts with `ro`/`rw` overrides, one-off `run --volume/-v`, runtime-scoped `volumes`, `volumes --format table/json`, `volumes --quiet/-q`, `rm --volumes/-v` for anonymous volumes, `down --volumes` for named project volumes | `ClientVolume.create(name:driver:driverOpts:labels:)`, `ClientVolume.list()`, `ClientVolume.delete(name:)`, `container volume create --opt`, inherited declared service mounts lowered to `container create/run --volume`, `container create --volume`, `container create --tmpfs`, `container create --mount type=tmpfs`, `container run --volume`, `container run --tmpfs`, `container run --mount type=tmpfs` | [S1](#s1-supported-local-web-stack) |
| Common runtime options | `command`, `entrypoint`, one-off `run --entrypoint`, `container_name`, `working_dir`, one-off `run --workdir`, `user`, one-off `run --user`, `tty`, one-off `run -T/--no-tty`, `stdin_open`, `read_only`, `init`, `platform`, `runtime`, `dns`, `dns_search`, `dns_opt`, `cap_add`, `cap_drop`, `cpus`, `mem_limit`, `deploy.resources.limits.cpus`, `deploy.resources.limits.memory`, `shm_size`, `ulimits`, `stop_signal`, `stop_grace_period` | `container create`, `container run`, `container create/run --entrypoint --workdir --user --tty --interactive --read-only --init --platform --runtime --dns --dns-search --dns-option --cap-add --cap-drop --cpus --memory --shm-size --ulimit`, and `ContainerClient.stop(id:opts:)` | [S1](#s1-supported-local-web-stack) |
| Environment and metadata | Service `environment`, `env_file`, one-off `run --env/-e`, one-off `run --env-from-file`, one-off `run --label/-l`, service labels, service annotations mapped to runtime metadata labels, `label_file`, network labels, volume labels, Compose project/service/config-hash labels | `container create --env`, `container create --env-file`, `container run --env`, `container run --env-file`, resource/container labels | [S1](#s1-supported-local-web-stack) |
| Simple ordering | `depends_on` with no condition or `condition: service_started`, service `volumes_from` implicit dependencies, default `required: true` behavior, optional `required: false` dependencies when present or omitted from the normalized project, and single-replica `depends_on.<service>.restart: true` propagation when `up` recreates or restarts that dependency; `up --always-recreate-deps` for explicitly selected services; `run` starts supported dependencies before the one-off container; `up --no-deps` for selected services and `run --no-deps` for one-off containers | Plugin dependency ordering before `container run`, dependency-change tracking during `up`, `ContainerClient.stop(id:opts:)`, `ContainerClient.start(id:)`, with optional missing dependencies skipped and dependency traversal/validation skipped when explicitly requested | [S1](#s1-supported-local-web-stack) |

### Blocked By apple/container

These are valid Docker Compose v2 surfaces. `container-compose` recognizes them, but [`apple/container`][apple-container] does not expose a Docker Compose compatible runtime primitive yet.

| Compose v2 surface | Examples of fields or commands | Missing [`apple/container`][apple-container] primitive | Example |
| --- | --- | --- | --- |
| Rich network attachment and IPAM controls | Multiple service networks, `aliases`, service network `driver_opts` other than supported MTU, `gw_priority`, `interface_name`, `ipv4_address`, `ipv6_address`, `link_local_ips`, `priority`, `network_mode` values other than `none`, project network IPAM `gateway`, `ip_range`, `aux_addresses`, custom IPAM drivers, and multiple same-family IPAM subnets | Multi-network attach/connect, per-network aliases/options beyond MAC and MTU, fixed addresses, Docker-compatible namespace modes, and richer project network IPAM controls | [A1](#a1-apple-gap-networking) |
| Host identity and legacy links | `hostname`, `domainname`, `extra_hosts`, `links`, `external_links` | Hostname/domain controls, explicit host entries, legacy link/alias semantics | [A2](#a2-apple-gap-host-identity-and-links) |
| Namespace and resource controls | `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, `isolation`, CPU scheduler controls beyond supported `cpus`, and memory/OOM/PID controls beyond supported `mem_limit` | Namespace selection, parent cgroups, CPU scheduler controls beyond `cpus`, memory controls beyond `mem_limit`, swap/OOM/PID controls | [A3](#a3-apple-gap-runtime-controls) |
| User, security, devices, and kernel tuning | `group_add`, `security_opt`, service `privileged`, `exec --privileged`, `credential_spec`, `device_cgroup_rules`, `devices`, `gpus`, `sysctls` | Supplemental groups, security profiles beyond supported `cap_add`/`cap_drop`, privileged mode, host devices, GPUs, per-container sysctls, privileged exec processes | [A3](#a3-apple-gap-runtime-controls) |
| Health, completion, configs, secrets, service restart | `healthcheck`, `depends_on.condition: service_healthy`, `depends_on.condition: service_completed_successfully`, service-level `configs`, service-level `secrets`, service `restart` | Health status, exit code/completion-time metadata, config/secret mount primitives, restart policy support | [A4](#a4-apple-gap-health-secrets-and-restart) |
| Runtime data and dynamic port commands | `ports` entries without an explicit host port such as `"80"` or `"8080"`, `top`, `events`, `pause`, `unpause`, already-stopped `wait` exit-code replay, `stats --no-trunc`, `cp --archive`, `cp --follow-link` | Dynamic host-port allocation, process listing, event stream, pause/unpause, stored process exit codes after container stop, stats truncation control, copy archive/follow-link controls | [A5](#a5-apple-gap-runtime-data-commands) |

### Blocked By `container-compose`

These are valid Docker Compose v2 surfaces where [`apple/container`][apple-container] is not known to be the first blocker. The missing design, orchestration, or safety policy belongs in this repository.

| Compose v2 surface | Examples of fields or commands | Missing plugin work | Example |
| --- | --- | --- | --- |
| Replica scaling edge cases and local deploy handling | Scaled services that publish a single fixed host port, publish too-small host ranges, set fixed MAC addresses, use `container_name`, or use anonymous volumes, and `deploy` fields beyond local replica count and CPU/memory limits | Dynamic allocation for fixed/single host ports, per-replica MAC policy, per-replica anonymous volume naming, and a local interpretation of deploy mode/placement/update/rollback/endpoint/labels/restart/resources beyond local replica count and CPU/memory limits | [C1](#c1-plugin-gap-replica-scaling-edge-cases-and-deploy) |
| Advanced build configuration | `additional_contexts`, `entitlements`, build `extra_hosts`, build `isolation`, build `network`, build `privileged`, `provenance`, `sbom`, build secrets without top-level `file` or `environment` backing, build secret `uid`/`gid`/`mode`, build `shm_size`, `ssh`, build `ulimits` | Safe translation to `container build` behavior and tests | [C2](#c2-plugin-gap-advanced-build-fields) |
| Develop, providers, models, hooks | `develop.watch`, service `provider`, service `models`, `post_start`, `pre_stop` | File-watch loops, sync/rebuild/restart action execution, provider/model wiring, lifecycle hook safety and ordering | [C3](#c3-plugin-gap-develop-providers-models-and-hooks) |
| Metadata, logging, storage shortcuts | `logging`, `log_driver`, `log_opt`, `storage_opt`, `volumes_from` external-container references, image-declared volume inheritance through `volumes_from`, service-level `volume_driver`, advanced service volume options such as bind propagation/SELinux/recursive controls, volume labels/nocopy/subpath, image mounts, and mount consistency | Runtime mapping, external/inferred inherited mount behavior, logging behavior, storage option and advanced mount policy | [C4](#c4-plugin-gap-metadata-storage-and-api-socket) |
| API socket and block I/O | `use_api_socket`, `blkio_config` | Security review and resource-control mapping | [C4](#c4-plugin-gap-metadata-storage-and-api-socket) |
| Additional CLI commands | default stdin/signal-proxy `attach`, `commit`, `publish` | Command design, output compatibility, and runtime mapping | [C5](#c5-plugin-gap-additional-cli-commands) |

### Config-Only Today

These Compose surfaces are useful in normalized output, but they do not currently change runtime orchestration.

| Compose v2 surface | Current behavior | Example |
| --- | --- | --- |
| Top-level and service `x-*` extensions | Preserved by `container compose config` and `container compose convert`; no runtime behavior by itself | [O1](#o1-config-only-metadata) |
| Service `expose` | Preserved by `config` and `convert`; it does not publish host ports. Use `ports` for host publishing | [O1](#o1-config-only-metadata) |
| Top-level `configs` and `secrets` definitions | Preserved by `config` and `convert`; file-backed and environment-backed secrets can feed supported `build.secrets`; service-level consumption is an [`apple/container`][apple-container] gap because mounts need runtime support | [S1](#s1-supported-local-web-stack), [O1](#o1-config-only-metadata), [A4](#a4-apple-gap-health-secrets-and-restart) |
| Top-level `models` definitions | Preserved by `config` and `convert`; service-level model bindings are a plugin gap | [O1](#o1-config-only-metadata), [C3](#c3-plugin-gap-develop-providers-models-and-hooks) |

## CLI Command Status

| Status | Commands |
| --- | --- |
| Supported | `config`, `convert`, `create`, `create --scale`, `create --quiet-pull`, `up`, `up --scale`, `up --no-build`, `up --quiet-build`, `up --quiet-pull`, `up --no-start`, `up --always-recreate-deps`, `up --timeout`, `scale`, `scale --no-deps`, `down`, `build`, `build --pull`, `build --push`, `build --quiet/-q`, `build --with-dependencies`, `pull`, `pull --include-deps`, `pull --ignore-buildable`, `pull --ignore-pull-failures`, `pull --policy always/missing`, `pull --quiet/-q`, `push`, `push --include-deps`, `push --ignore-push-failures`, `push --quiet/-q`, `ls`, `ps`, `logs`, `logs --index`, `logs --no-color`, `logs --no-log-prefix`, output-only `attach --no-stdin --sig-proxy=false`, `attach --index`, `exec`, `exec --index`, `run`, `start`, `stop`, `restart`, `rm`, `images`, `volumes`, `stats`, `stats --all`, `cp`, `cp --index`, `export`, `export --index`, explicit published-port `port`, `port --index`, `kill`, `wait` for running/stopping service containers, `wait --down-project` for running/stopping service containers, `version` |
| Present but blocked by [`apple/container`][apple-container] runtime gaps | dynamic host-port allocation, `top`, `events`, `pause`, `unpause`, already-stopped `wait` exit-code replay, `stats --no-trunc`, `cp --archive`, `cp --follow-link` |
| Present but blocked by `container-compose` design gaps | `watch` file-watch/action execution, default stdin/signal-proxy `attach`, `commit`, `publish` |

## References

- Compose file reference: [docs.docker.com/reference/compose-file](https://docs.docker.com/reference/compose-file/).
- Docker Compose v2 CLI reference: [docs.docker.com/reference/cli/docker/compose](https://docs.docker.com/reference/cli/docker/compose/).
- Docker Compose v2 implementation: [`docker/compose`](https://github.com/docker/compose).
- Docker Compose v2 Go API package: [`github.com/docker/compose/v2/pkg/api`](https://pkg.go.dev/github.com/docker/compose/v2/pkg/api).
- Compose model normalizer used here: [`compose-spec/compose-go`](https://github.com/compose-spec/compose-go).
- Apple container public documentation: [apple.github.io/container/documentation](https://apple.github.io/container/documentation/).
- Apple `ContainerClient` API documentation for direct Swift runtime adapter work: [apple.github.io/container/documentation/containerclient](https://apple.github.io/container/documentation/containerclient/).

## Example Index

Every example includes a Compose file or commands plus the matching Dockerfile snippets needed to try the surface in an isolated scratch directory.

| Example | Status bucket | What it demonstrates |
| --- | --- | --- |
| [S1: Supported Local Web Stack](#s1-supported-local-web-stack) | Supported | Build, images, `create`, ports, static `port`, environment, one network, no-network services, single-network MAC addresses, volume mounts, `volumes`, labels, `label_file`, lifecycle, logs, exec, stats, copy, and `down --volumes` |
| [A1: Apple Gap, Networking](#a1-apple-gap-networking) | [`apple/container`][apple-container] gap | Multiple networks, aliases, fixed IP attachment options, network namespace modes other than no-network, and IPAM controls beyond one IPv4/IPv6 subnet |
| [A2: Apple Gap, Host Identity And Links](#a2-apple-gap-host-identity-and-links) | [`apple/container`][apple-container] gap | Hostname, domain name, explicit host entries, and legacy links |
| [A3: Apple Gap, Runtime Controls](#a3-apple-gap-runtime-controls) | [`apple/container`][apple-container] gap | Namespace controls, privileged/device access, resource controls beyond the supported local limits, and sysctls |
| [A4: Apple Gap, Health, Secrets, And Restart](#a4-apple-gap-health-secrets-and-restart) | [`apple/container`][apple-container] gap | Healthchecks, healthy/completed dependency gates, service secrets/configs, and restart policies |
| [A5: Apple Gap, Runtime Data Commands](#a5-apple-gap-runtime-data-commands) | [`apple/container`][apple-container] gap | Process listing, event streams, dynamic host-port allocation, pause/unpause, already-stopped exit-code replay, and stats truncation control |
| [C1: Plugin Gap, Replica Scaling Edge Cases And Deploy](#c1-plugin-gap-replica-scaling-edge-cases-and-deploy) | `container-compose` gap | Scaled fixed-port collisions, per-replica anonymous volumes, DNS, and deploy semantics |
| [C2: Plugin Gap, Advanced Build Fields](#c2-plugin-gap-advanced-build-fields) | `container-compose` gap | Additional contexts, unsupported secret forms and metadata, SSH, and provenance/SBOM fields |
| [C3: Plugin Gap, Develop, Providers, Models, And Hooks](#c3-plugin-gap-develop-providers-models-and-hooks) | `container-compose` gap | Watch/develop, providers, model bindings, and lifecycle hooks |
| [C4: Plugin Gap, Metadata, Storage, And API Socket](#c4-plugin-gap-metadata-storage-and-api-socket) | `container-compose` gap | Logging options, external inherited mounts, advanced service volume options, API socket, and block I/O |
| [C5: Plugin Gap, Additional CLI Commands](#c5-plugin-gap-additional-cli-commands) | `container-compose` gap | Compose v2 commands that still need command-level plugin design |
| [O1: Config-Only Metadata](#o1-config-only-metadata) | Config-only | Extension metadata, top-level models/secrets, and `expose` in normalized output |

## Examples With Dockerfiles

### S1: Supported Local Web Stack

Expected result: `container compose config`, `container compose convert`, `build --pull --with-dependencies --quiet`, `build --push`, `pull --include-deps --policy missing --quiet`, `push --include-deps --quiet`, `create`, `create --quiet-pull`, `up`, `up --quiet-build`, `up --quiet-pull`, `up --always-recreate-deps`, `up --timeout`, service `attach: false`, `ps`, `logs`, `exec`, `stats`, `wait` and `wait --down-project` for running/stopping service containers, `cp`, `volumes`, `rm --force --volumes` for anonymous volumes, and `down --volumes` run through [`apple/container`][apple-container].

Status path:

- Docker Compose v2: accepts and normalizes this project.
- [`apple/container`][apple-container]: has the needed build, image, lifecycle, discovery, network, volume, log, exec, wait, copy, and export primitives.
- `container-compose`: maps the normalized model to those primitives.

```yaml
# compose.yaml
name: supported-demo

services:
  api:
    build:
      context: ./api
      dockerfile: Dockerfile
      no_cache: true
      pull: true
      args:
        APP_ENV: dev
      cache_from:
        - type=registry,ref=example/api:cache
      cache_to:
        - type=local,dest=.cache
      labels:
        org.opencontainers.image.title: api
      platforms:
        - linux/arm64
      tags:
        - example/api:local
      secrets:
        - source: build_cert
        - source: npm_token
          target: npm_token
    image: example/api:dev
    pull_policy: missing
    command: ["sh", "-c", "printf 'ready\n'; sleep 3600"]
    environment:
      API_MODE: local
    env_file:
      - ./api.env
    ports:
      - "8080:8080"
    mac_address: "02:42:ac:11:00:03"
    volumes:
      - api-cache:/cache
      - ./config:/config:ro
      - type: tmpfs
        target: /scratch
        tmpfs:
          size: 64m
          mode: 1777
    tmpfs:
      - /run
    networks:
      app:
        driver_opts:
          com.docker.network.driver.mtu: "1450"
    depends_on:
      worker:
        condition: service_started
    cpus: "1.5"
    mem_limit: 256m
    deploy:
      resources:
        limits:
          cpus: "1.5"
          memory: 256m
    shm_size: 64m
    dns_opt:
      - use-vc
    init: true
    stop_signal: SIGTERM
    stop_grace_period: 10s
    labels:
      example.com/service: api
    label_file:
      - ./api.labels

  worker:
    build:
      context: ./worker
    command: ["sh", "-c", "while true; do echo worker; sleep 30; done"]
    networks:
      - app

  isolated:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 3600"]
    network_mode: none

networks:
  app:
    internal: true
    labels:
      example.com/network: app
    ipam:
      config:
        - subnet: "10.77.0.0/24"
        - subnet: "fd77::/64"

volumes:
  api-cache:
    driver: local
    driver_opts:
      size: 1g
      journal: ordered
    labels:
      example.com/volume: cache

secrets:
  build_cert:
    file: ./build-cert.pem
  npm_token:
    environment: NPM_TOKEN
```

Dockerfile: `api/Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1
FROM alpine:3.20
ARG APP_ENV=dev
RUN --mount=type=secret,id=build_cert --mount=type=secret,id=npm_token \
    test -s /run/secrets/build_cert && test -s /run/secrets/npm_token
RUN mkdir -p /app /cache /config && printf '%s\n' "$APP_ENV" > /app/env.txt
EXPOSE 8080
CMD ["sh", "-c", "sleep 3600"]
```

File: `build-cert.pem`

```text
local-build-secret-placeholder
```

File: `api.env`

```env
API_TRACE=1
```

File: `api.labels`

```env
example.com/label-file=enabled
```

Dockerfile: `worker/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

Useful supported commands against this project:

```sh
export NPM_TOKEN=local-build-secret-placeholder
container compose config
container compose build --pull --with-dependencies --quiet api
container compose build --push api
container compose pull --include-deps --policy missing --quiet api
container compose push --include-deps --quiet api
container compose create --build
container compose create --pull always --quiet-pull api
container compose create --pull build api
container compose create --no-build worker
container compose create --scale worker=2 worker
container compose up --pull missing
container compose up --pull always --quiet-pull api
container compose up --always-recreate-deps api
container compose up --scale worker=2 worker
container compose up --timeout 12 api
container compose up --no-build
container compose up --quiet-build worker
container compose up --no-deps api
container compose up --no-start api
container compose up --no-start --no-deps api
container compose ls
container compose ls --all
container compose ls --filter name=supported-demo
container compose ls --format json
container compose ls --quiet
container compose images --format json
container compose images -q
container compose run --pull missing api true
container compose run --no-deps api true
container compose run --rm api printf ok
container compose run --detach api sleep 60
container compose run --name api-shell api sh
container compose run --service-ports api printf ok
container compose run -p 9090:8080 api printf ok
container compose run --entrypoint "/bin/sh -c" api "printf ok"
container compose run --workdir /app api pwd
container compose run --user 1000:1000 api id
container compose run -T api sh
container compose run -e LOG_LEVEL=debug --env-from-file .env.local api env
container compose run -l com.example.role=job api true
container compose run -v ./scratch:/scratch:ro api ls /scratch
container compose ps
container compose ps --quiet
container compose ps --services
container compose ps --status running
container compose ps --filter status=exited
container compose logs api
container compose logs --index 2 api
container compose logs --no-color --no-log-prefix api
container compose attach --no-stdin --sig-proxy=false api
container compose attach --no-stdin --sig-proxy=false --index 2 api
container compose exec api sh
container compose exec -T api echo ok
container compose exec --interactive=false -T api echo ok
container compose exec -d api sleep 60
container compose exec -e DEBUG=1 api env
container compose exec -u 1000:1000 api id
container compose exec -w /app api pwd
container compose exec --index 2 api true
container compose stats
container compose stats --all
container compose stats --no-stream --format json api worker
container compose volumes
container compose volumes --format json api
container compose volumes --quiet worker
container compose cp api:/app/env.txt ./env.txt
container compose cp --index 2 api:/app/env.txt ./env.txt
container compose cp --all ./seed.sql api:/tmp/seed.sql
container compose export --index 2 -o api.tar api
container compose port api 8080
container compose port --index 2 api 8080
container compose stop --timeout 12 api
container compose restart -t 12 api
container compose kill worker
container compose wait worker
container compose wait --down-project worker
container compose down --timeout 12 --volumes
container compose down --rmi local --timeout 12 --volumes
```

### A1: Apple Gap, Networking

Expected result: `container compose up` rejects this before creating resources because [`apple/container`][apple-container] needs multi-network attach/connect, per-network aliases/options beyond MAC and MTU, fixed addresses, network namespace modes other than no-network, and IPAM controls beyond one IPv4/IPv6 subnet.

Status path:

- Docker Compose v2: accepts and normalizes these network attachments.
- [`apple/container`][apple-container]: missing multi-network attach/connect, per-network aliases/options beyond MAC and MTU, fixed addresses, Docker-compatible namespace modes other than no-network, IPAM gateway/range/auxiliary-address controls, custom IPAM drivers, and multiple same-family IPAM subnets.
- `container-compose`: detects those fields and fails before creating resources.

```yaml
# compose.yaml
name: apple-network-gap-demo

services:
  api:
    build:
      context: ./api
    networks:
      app:
        aliases:
          - api.internal
      admin:
        ipv4_address: 10.10.0.20

  sidecar:
    build:
      context: ./sidecar
    network_mode: service:gateway

  gateway:
    build:
      context: ./gateway
    networks:
      - app

networks:
  app:
    ipam:
      driver: custom
      config:
        - subnet: "10.10.0.0/24"
          gateway: "10.10.0.1"
        - subnet: "10.11.0.0/24"
  admin: {}
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

Dockerfile: `sidecar/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

Dockerfile: `gateway/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

### A2: Apple Gap, Host Identity And Links

Expected result: `container compose up` rejects this because [`apple/container`][apple-container] needs host identity, explicit host-entry, and link semantics.

Status path:

- Docker Compose v2: accepts and normalizes host identity and legacy link fields.
- [`apple/container`][apple-container]: missing hostname/domain controls, explicit host-entry support, and legacy link semantics.
- `container-compose`: detects those fields and reports the Apple runtime gap.

```yaml
# compose.yaml
name: apple-host-gap-demo

services:
  api:
    build:
      context: ./api
    hostname: api-01
    domainname: local.test
    extra_hosts:
      - "host.docker.internal:host-gateway"
    links:
      - db:database

  db:
    build:
      context: ./db
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

Dockerfile: `db/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

### A3: Apple Gap, Runtime Controls

Expected result: `container compose up` rejects this because [`apple/container`][apple-container] needs namespace, resource controls beyond the supported local CPU/memory/ulimit subset, privileged/device, and sysctl primitives. `container compose exec --privileged` is rejected because privileged exec processes need an [`apple/container`][apple-container] primitive.

Status path:

- Docker Compose v2: accepts and normalizes these runtime controls.
- [`apple/container`][apple-container]: missing the required namespace, privileged/device, resource controls beyond supported `cpus`, `mem_limit`, `shm_size`, and `ulimits`, sysctl, and privileged exec primitives.
- `container-compose`: detects those fields and reports the Apple runtime gap.

The related exec form is also rejected:

```sh
container compose exec --privileged api true
```

```yaml
# compose.yaml
name: apple-runtime-gap-demo

services:
  api:
    build:
      context: ./api
    pid: host
    ipc: host
    cgroup_parent: local.slice
    privileged: true
    devices:
      - "/dev/fuse:/dev/fuse"
    group_add:
      - audio
    security_opt:
      - no-new-privileges:true
    cpu_quota: 50000
    memswap_limit: 512m
    pids_limit: 128
    sysctls:
      net.ipv4.ip_local_port_range: "1024 65000"
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

### A4: Apple Gap, Health, Secrets, And Restart

Expected result: `container compose up` rejects this because [`apple/container`][apple-container] needs health status, completion metadata, config/secret mounts, and restart policies.

Status path:

- Docker Compose v2: accepts and normalizes healthchecks, dependency conditions, configs, secrets, and restart policies.
- [`apple/container`][apple-container]: missing health status, exit/completion metadata, config/secret mount primitives, and restart policy support.
- `container-compose`: detects those fields and reports the Apple runtime gap.

```yaml
# compose.yaml
name: apple-health-gap-demo

services:
  migrate:
    build:
      context: ./migrate
    command: ["sh", "-c", "touch /tmp/done"]

  api:
    build:
      context: ./api
    healthcheck:
      test: ["CMD", "test", "-f", "/tmp/ready"]
      interval: 5s
      timeout: 2s
      retries: 3
    restart: unless-stopped
    configs:
      - api_config
    secrets:
      - api_token
    depends_on:
      migrate:
        condition: service_completed_successfully

  worker:
    build:
      context: ./worker
    depends_on:
      api:
        condition: service_healthy

configs:
  api_config:
    file: ./api.conf

secrets:
  api_token:
    file: ./api-token.txt
```

Dockerfile: `migrate/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "touch /tmp/done"]
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "touch /tmp/ready && sleep 3600"]
```

Dockerfile: `worker/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "echo worker-ready && sleep 3600"]
```

### A5: Apple Gap, Runtime Data Commands

Expected result: these commands and options reject because [`apple/container`][apple-container] needs richer runtime data and state controls. `container compose port` supports explicit published bindings from runtime container snapshots, including explicit ranges and indexed existing service containers, but Docker Compose dynamic host-port allocation needs runtime behavior that [`apple/container`][apple-container] does not expose yet. Plain service-aware `container compose cp` is supported, but `cp --archive` and `cp --follow-link` reject until [`apple/container`][apple-container] exposes copy archive and symlink-follow controls. `container compose wait` and `container compose wait --down-project` can wait for running or stopping service containers, but replaying exit codes for containers that were already stopped before the command starts still needs stored exit-code metadata from [`apple/container`][apple-container].

Status path:

- Docker Compose v2: supports these commands.
- [`apple/container`][apple-container]: missing dynamic host-port allocation, process listing, event streaming, pause/unpause, stored exit-code metadata for already-stopped containers, stats truncation control, and copy archive/follow-link controls.
- `container-compose`: exposes the command names, resolves explicit published-port lookups from runtime snapshots, supports indexed target lookup for existing Compose-managed service containers, supports `stats --all` by combining direct stats for running containers with stopped-container metadata from project discovery, supports `wait` and `wait --down-project` for running/stopping service containers, and reports the Apple runtime gap for requests that need unavailable runtime state.

```yaml
# compose.yaml
name: apple-command-gap-demo

services:
  api:
    build:
      context: ./api
    ports:
      - "8080"

  worker:
    build:
      context: ./worker
```

Run:

```sh
container compose top api
container compose events --json
container compose up api
container compose port api 8080
container compose pause api
container compose unpause api
container compose stats --no-trunc api
container compose cp --archive api:/tmp/report.txt ./report.txt
container compose cp --follow-link api:/tmp/report.txt ./report.txt
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
EXPOSE 8080
CMD ["sh", "-c", "sleep 3600"]
```

Dockerfile: `worker/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

### C1: Plugin Gap, Replica Scaling Edge Cases And Deploy

Expected result: `container compose up` accepts simple local replica counts for services that can be safely duplicated, including services with explicit host port ranges large enough to allocate one deterministic slice per replica. It rejects this example because `update_config` still needs Compose deploy orchestration semantics beyond local replica count and CPU/memory limits. Scaled services are currently limited to Compose-managed names and services without fixed/single host-port collisions, fixed MAC addresses, or anonymous volumes.

Status path:

- Docker Compose v2: accepts and normalizes scaling and deploy metadata.
- [`apple/container`][apple-container]: not known to be the first blocker for this example.
- `container-compose`: maps standalone `scale`, `up --scale`, `create --scale`, service `scale`, and local `deploy.replicas` to indexed containers; maps large enough published-port ranges to deterministic per-replica host ports; maps `deploy.resources.limits.cpus` and `deploy.resources.limits.memory` to local runtime limits; and can target indexed service containers for `logs`, `attach`, `exec`, `cp`, `export`, and `port`. It still needs dynamic allocation for fixed/single host ports, per-replica anonymous volume handling, DNS semantics, and broader deploy semantics.

The equivalent supported CLI scaling forms are:

```sh
container compose scale worker=3
container compose up --scale worker=3 worker
container compose up --scale api=2 api
```

```yaml
# compose.yaml
name: plugin-scale-gap-demo

services:
  worker:
    build:
      context: ./worker
    deploy:
      replicas: 3
      update_config:
        parallelism: 1

  api:
    build:
      context: ./api
    ports:
      - "8080-8081:80"
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

Dockerfile: `worker/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

### C2: Plugin Gap, Advanced Build Fields

Expected result: `container compose build` rejects this before running `container build` because the advanced build fields and secret metadata need safe plugin mapping first.

Status path:

- Docker Compose v2: accepts and normalizes these build fields.
- [`apple/container`][apple-container]: not known to be the first blocker for this example.
- `container-compose`: needs explicit, tested mappings for advanced build behavior before invoking `container build`.

```yaml
# compose.yaml
name: plugin-build-gap-demo

services:
  api:
    build:
      context: ./api
      dockerfile: Dockerfile
      additional_contexts:
        shared: ./shared
      secrets:
        - source: npm_token
          uid: "1000"
          mode: 0400
      ssh:
        - default

secrets:
  npm_token:
    file: ./npm-token.txt
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
RUN mkdir -p /app
CMD ["sh", "-c", "sleep 3600"]
```

### C3: Plugin Gap, Develop, Providers, Models, And Hooks

Expected result: `container compose config` preserves the `develop.watch` trigger metadata, and `container compose watch api` validates service selection and trigger shape before reporting that file watching and develop actions are not implemented yet. `container compose up` rejects this because watch/develop, provider/model wiring, and lifecycle hooks need plugin orchestration.

Status path:

- Docker Compose v2: accepts and normalizes develop, provider, model, and hook fields.
- [`apple/container`][apple-container]: not known to be the first blocker for this example.
- `container-compose`: preserves normalized `develop.watch` trigger metadata and validates `watch` command selections. It still needs file watching, sync/rebuild/restart action execution, service providers, model bindings, and hook execution.

```yaml
# compose.yaml
name: plugin-extension-gap-demo

models:
  llm:
    model: example/local-llm

services:
  api:
    build:
      context: ./api
    provider:
      type: example
    models:
      llm:
        endpoint_var: MODEL_ENDPOINT
    post_start:
      - command: ["sh", "-c", "echo started"]
    pre_stop:
      - command: ["sh", "-c", "echo stopping"]
    develop:
      watch:
        - path: ./api/src
          target: /app/src
          action: sync
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
WORKDIR /app
CMD ["sh", "-c", "sleep 3600"]
```

Current command boundary:

```sh
container compose config
container compose watch --no-up --no-prune --quiet api
```

### C4: Plugin Gap, Metadata, Storage, And API Socket

Expected result: `container compose up` rejects this because logging/storage options, external inherited mounts, advanced service volume options, API socket exposure, and block I/O controls need plugin implementation and security review.

Status path:

- Docker Compose v2: accepts and normalizes these service fields.
- [`apple/container`][apple-container]: not known to be the first blocker for this grouped example.
- `container-compose`: maps service `pull_policy: daily`, `weekly`, and `every_<duration>` through direct image pulls and local pull timestamp metadata, maps service `pull_policy: build` through the existing build path, maps service annotations to Apple runtime metadata labels, maps same-project service `volumes_from` for declared Compose mounts, and maps long-form tmpfs `size`/`mode` through Apple `container --mount type=tmpfs`. It still needs runtime mapping, external-container and image-declared volume inheritance, advanced volume option policy beyond tmpfs size/mode, logging/storage policy, API socket security review, and block I/O handling.

```yaml
# compose.yaml
name: plugin-misc-gap-demo

services:
  base:
    build:
      context: ./base
    volumes:
      - shared-data:/data

  worker:
    build:
      context: ./worker
    depends_on:
      base:
        condition: service_started
    logging:
      driver: json-file
    volumes_from:
      - container:legacy-worker:ro
    volumes:
      - type: volume
        source: shared-data
        target: /data
        volume:
          nocopy: true
          subpath: worker
    use_api_socket: true
    blkio_config:
      weight: 300

volumes:
  shared-data: {}
```

Dockerfile: `base/Dockerfile`

```dockerfile
FROM alpine:3.20
RUN mkdir -p /data
CMD ["sh", "-c", "sleep 3600"]
```

Dockerfile: `worker/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

### C5: Plugin Gap, Additional CLI Commands

Expected result: these Docker Compose v2 commands and default attach semantics are recognized by `container-compose` and fail with command-specific design gap messages.

Status path:

- Docker Compose v2: supports these commands and default attach behavior.
- [`apple/container`][apple-container]: command-specific runtime availability still needs to be assessed as each command is implemented.
- `container-compose`: exposes these command names and reports design gaps instead of failing as unknown subcommands. `watch` command validation is tracked in [C3](#c3-plugin-gap-develop-providers-models-and-hooks).

```yaml
# compose.yaml
name: plugin-command-gap-demo

services:
  api:
    build:
      context: ./api
    image: example/api:dev

  worker:
    build:
      context: ./worker
```

Compare the missing command behavior:

```sh
docker compose attach api
docker compose commit api example/api:snapshot
docker compose publish
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
RUN mkdir -p /app
CMD ["sh", "-c", "sleep 3600"]
```

Dockerfile: `worker/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

### O1: Config-Only Metadata

Expected result: `container compose config` preserves this metadata. Runtime commands do not publish `expose`, do not act on `x-*`, and reject service-level model/config/secret consumption when it needs runtime behavior.

Status path:

- Docker Compose v2: accepts and normalizes this metadata.
- [`apple/container`][apple-container]: no primitive is required for read-only `config` output.
- `container-compose`: preserves the metadata for `config`; runtime commands only apply fields that have a supported mapping.

```yaml
# compose.yaml
name: config-only-demo

x-owner: platform

models:
  llm:
    model: example/local-llm

secrets:
  api_token:
    file: ./api-token.txt

services:
  api:
    build:
      context: ./api
    expose:
      - "8080"
    x-purpose: local smoke test
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

## Maintenance Rule

When a change adds, removes, or changes a Compose-to-[`apple/container`][apple-container] runtime mapping, update this file in the same commit or pull request. Do not mark a primitive as supported until the orchestrator maps it, unsupported alternatives fail clearly, and focused tests cover the behavior.

[apple-container]: https://github.com/apple/container
