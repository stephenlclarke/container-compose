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
| Build and images | `build.context`, `build.dockerfile`, `build.args`, `build.cache_from`, `build.cache_to`, `build.labels`, `build.platforms`, `build.target`, `build.no_cache`, `build.pull`, `build.tags`, CLI `build --no-cache`, `pull`, `push`, runtime-scoped `images`, `images --format table/json`, `images --quiet/-q`, global `up --pull always/missing/if_not_present/never`, `create --pull always/missing/if_not_present/never/build`, `create --build`, `create --no-build`, one-off `run --pull always/missing/if_not_present/never`, service `pull_policy: always/missing/if_not_present/never`, image removal through `down --rmi local/all` | `container build --pull --platform --cache-in --cache-out --tag --label`, `ClientImage.pull(reference:platform:scheme:containerSystemConfig:progressUpdate:maxConcurrentDownloads:)`, `ClientImage.get(names:containerSystemConfig:)`, `ClientImage.push(platform:scheme:containerSystemConfig:progressUpdate:)`, `ClientImage.delete(reference:garbageCollect:)`, `ClientImage.cleanUpOrphanedBlobs()`, `ContainerClient.list(filters:)` | [S1](#s1-supported-local-web-stack) |
| Container lifecycle | `create`, `up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, `rm --force/-f`, `kill`, deterministic names, one-off names, config-hash recreate, `--force-recreate`, `--no-recreate`, `--remove-orphans`, `down --rmi local/all`, `stop/restart/down --timeout`, one-off `run --rm`, one-off `run --detach/-d`, one-off `run --name` | `container create`, `container run`, `ContainerClient.bootstrap(id:stdio:dynamicEnv:)`, `ClientProcess.start()`, `ContainerClient.get(id:)`, `ContainerClient.list(filters:)`, `ContainerClient.stop(id:opts:)`, `ContainerClient.delete(id:force:)`, `ContainerClient.kill(id:signal:)` | [S1](#s1-supported-local-web-stack) |
| Project discovery | `ls`, `ls --all/-a`, `ls --format table/json`, `ls --quiet/-q`, and `ls --filter name=...` from project labels on created containers | `ContainerClient.list(filters:)` and Compose project/config-hash labels | [S1](#s1-supported-local-web-stack) |
| Container interaction | `ps`, `ps --quiet`, `ps --services`, `ps --status running/exited`, `ps --filter status=...`, `logs`, `exec` with Compose-default stdin/TTY, `exec -T/--no-tty`, `exec --interactive=false`, `exec --detach/-d`, `exec --env/-e`, `exec --user/-u`, `exec --workdir/-w`, `exec --index 1`, service-aware `cp`, service-to-service `cp`, `cp --index 1`, local/service `cp --all` including one-off `run` containers, `export`, `export -o/--output`, `export --index 1`, `stats [SERVICE...]`, `stats --format table/json`, `stats --no-stream`, `version`, `version --short`, `version -f/--format pretty/json` | `ContainerClient.list(filters:)`, `ContainerClient.logs(id:)`, `ProcessIO.create(tty:interactive:detach:)`, `ContainerClient.createProcess(containerId:processId:configuration:stdio:)`, `ProcessIO.handleProcess(process:log:)` for attached exec, `ClientProcess.start()` for detached exec with `--env`, `--user`, and `--workdir`, `ContainerClient.copyIn(id:source:destination:)`, `ContainerClient.copyOut(id:source:destination:)`, staged service-to-service copies through `copyOut` then `copyIn`, `ContainerClient.list(filters:)` for one-off copy target discovery, `ContainerClient.export(id:archive:)`, `ContainerClient.stats(id:)`, plugin version output | [S1](#s1-supported-local-web-stack) |
| Default networking | One service network, default project networks, external networks, service ports for `create` and `up`, single-network service or per-network `mac_address`, `port` for static published bindings, one-off `run --service-ports/-P`, one-off `run --publish/-p` | `NetworkClient.create(configuration:)`, `NetworkClient.delete(id:)`, `container create --network <name>[,mac=...]`, `container create --publish`, `container run --network <name>[,mac=...]`, `container run --publish`, normalized Compose port metadata | [S1](#s1-supported-local-web-stack) |
| Default storage | Named volumes, external volumes, bind mounts, anonymous volumes, read-only mounts, tmpfs mounts, one-off `run --volume/-v`, runtime-scoped `volumes`, `volumes --format table/json`, `volumes --quiet/-q`, `rm --volumes/-v` for anonymous volumes, `down --volumes` for named project volumes | `ClientVolume.create(name:driver:driverOpts:labels:)`, `ClientVolume.list()`, `ClientVolume.delete(name:)`, `container create --volume`, `container create --tmpfs`, `container run --volume`, `container run --tmpfs` | [S1](#s1-supported-local-web-stack) |
| Common runtime options | `command`, `entrypoint`, one-off `run --entrypoint`, `container_name`, `working_dir`, one-off `run --workdir`, `user`, one-off `run --user`, `tty`, one-off `run -T/--no-tty`, `stdin_open`, `read_only`, `init`, `platform`, `runtime`, `dns`, `dns_search`, `dns_opt`, `cap_add`, `cap_drop`, `cpus`, `mem_limit`, `deploy.resources.limits.cpus`, `deploy.resources.limits.memory`, `shm_size`, `ulimits`, `stop_signal`, `stop_grace_period` | `container create`, `container run`, and `ContainerClient.stop(id:opts:)` | [S1](#s1-supported-local-web-stack) |
| Environment and labels | Service `environment`, `env_file`, one-off `run --env/-e`, one-off `run --env-from-file`, one-off `run --label/-l`, service labels, `label_file`, network labels, volume labels, Compose project/service/config-hash labels | `container create --env`, `container create --env-file`, `container run --env`, `container run --env-file`, resource/container labels | [S1](#s1-supported-local-web-stack) |
| Simple ordering | `depends_on` with no condition or `condition: service_started`, default `required: true` behavior, optional `required: false` dependencies when present or omitted from the normalized project, and single-replica `depends_on.<service>.restart: true` propagation when `up` recreates or restarts that dependency; `run` starts supported dependencies before the one-off container; `up --no-deps` for selected services and `run --no-deps` for one-off containers | Plugin dependency ordering before `container run`, dependency-change tracking during `up`, `ContainerClient.stop(id:opts:)`, `ContainerClient.start(id:)`, with optional missing dependencies skipped and dependency traversal/validation skipped when explicitly requested | [S1](#s1-supported-local-web-stack) |

### Blocked By apple/container

These are valid Docker Compose v2 surfaces. `container-compose` recognizes them, but [`apple/container`][apple-container] does not expose a Docker Compose compatible runtime primitive yet.

| Compose v2 surface | Examples of fields or commands | Missing [`apple/container`][apple-container] primitive | Example |
| --- | --- | --- | --- |
| Rich network attachment | Multiple service networks, `aliases`, `driver_opts`, `gw_priority`, `interface_name`, `ipv4_address`, `ipv6_address`, `link_local_ips`, `priority`, `network_mode` | Multi-network attach/connect, per-network aliases/options beyond MAC, fixed addresses, Docker-compatible namespace modes | [A1](#a1-apple-gap-networking) |
| Host identity and legacy links | `hostname`, `domainname`, `extra_hosts`, `links`, `external_links` | Hostname/domain controls, explicit host entries, legacy link/alias semantics | [A2](#a2-apple-gap-host-identity-and-links) |
| Namespace and resource controls | `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, `isolation`, advanced CPU controls, advanced memory/OOM/PID controls | Namespace selection, parent cgroups, CPU scheduler controls beyond `cpus`, memory controls beyond `mem_limit`, swap/OOM/PID controls | [A3](#a3-apple-gap-runtime-controls) |
| User, security, devices, and kernel tuning | `group_add`, `security_opt`, service `privileged`, `exec --privileged`, `credential_spec`, `device_cgroup_rules`, `devices`, `gpus`, `sysctls` | Supplemental groups, security profiles, privileged mode, host devices, GPUs, per-container sysctls, privileged exec processes | [A3](#a3-apple-gap-runtime-controls) |
| Health, completion, configs, secrets, service restart | `healthcheck`, `depends_on.condition: service_healthy`, `depends_on.condition: service_completed_successfully`, service-level `configs`, service-level `secrets`, service `restart` | Health status, exit code/completion-time metadata, config/secret mount primitives, restart policy support | [A4](#a4-apple-gap-health-secrets-and-restart) |
| Runtime data and state commands | `top`, `events`, dynamic `port` lookup, `port --index` values other than `1`, `pause`, `unpause`, `wait`, `stats --all`, `stats --no-trunc`, `cp --archive`, `cp --follow-link` | Process listing, event stream, runtime-discovered published-port inspect, pause/unpause, wait/exit metadata, stats all-container/truncation controls, copy archive/follow-link controls | [A5](#a5-apple-gap-runtime-data-commands) |

### Blocked By `container-compose`

These are valid Docker Compose v2 surfaces where [`apple/container`][apple-container] is not known to be the first blocker. The missing design, orchestration, or safety policy belongs in this repository.

| Compose v2 surface | Examples of fields or commands | Missing plugin work | Example |
| --- | --- | --- | --- |
| Replica scaling and local deploy handling | `scale`, `up --scale`, `deploy.replicas` values other than `1`, `exec --index` values other than `1`, `cp --index` values other than `1`, `deploy` fields beyond local replica count and CPU/memory limits | Multi-replica naming, reconciliation, DNS behavior, logs, `ps`, replica-aware `exec` and `cp`, service-to-service `cp --all`, removal, and a local interpretation of deploy mode/placement/update/rollback/endpoint/labels/restart/resources | [C1](#c1-plugin-gap-replica-scaling-and-deploy) |
| Advanced build configuration | `additional_contexts`, `dockerfile_inline`, `entitlements`, build `extra_hosts`, build `isolation`, build `network`, build `privileged`, `provenance`, `sbom`, build `secrets`, build `shm_size`, `ssh`, build `ulimits` | Safe translation to `container build` behavior and tests | [C2](#c2-plugin-gap-advanced-build-fields) |
| Develop, providers, models, hooks | `develop`, watch settings, service `provider`, service `models`, `post_start`, `pre_stop` | Watch/sync/rebuild orchestration, provider/model wiring, lifecycle hook safety and ordering | [C3](#c3-plugin-gap-develop-providers-models-and-hooks) |
| Metadata, logging, storage shortcuts | `annotations`, `attach`, `logging`, `log_driver`, `log_opt`, `storage_opt`, `volumes_from`, service-level `volume_driver` | Runtime mapping, inherited mount behavior, logging behavior, storage option policy | [C4](#c4-plugin-gap-metadata-storage-api-socket-and-pull-windows) |
| API socket, block I/O, pull windows | `use_api_socket`, `blkio_config`, service `pull_policy: build/daily/weekly/<duration>` | Security review, resource-control mapping, and time-window/build-trigger pull semantics | [C4](#c4-plugin-gap-metadata-storage-api-socket-and-pull-windows) |
| Additional CLI commands | `watch`, `scale`, `attach`, `commit`, `publish` | Command design, output compatibility, and runtime mapping | [C5](#c5-plugin-gap-additional-cli-commands) |

### Config-Only Today

These Compose surfaces are useful in normalized output, but they do not currently change runtime orchestration.

| Compose v2 surface | Current behavior | Example |
| --- | --- | --- |
| Top-level and service `x-*` extensions | Preserved by `container compose config` and `container compose convert`; no runtime behavior by itself | [O1](#o1-config-only-metadata) |
| Service `expose` | Preserved by `config` and `convert`; it does not publish host ports. Use `ports` for host publishing | [O1](#o1-config-only-metadata) |
| Top-level `configs` and `secrets` definitions | Preserved by `config` and `convert`; service-level consumption is an [`apple/container`][apple-container] gap because mounts need runtime support | [O1](#o1-config-only-metadata), [A4](#a4-apple-gap-health-secrets-and-restart) |
| Top-level `models` definitions | Preserved by `config` and `convert`; service-level model bindings are a plugin gap | [O1](#o1-config-only-metadata), [C3](#c3-plugin-gap-develop-providers-models-and-hooks) |

## CLI Command Status

| Status | Commands |
| --- | --- |
| Supported | `config`, `convert`, `create`, `up`, `down`, `build`, `pull`, `push`, `ls`, `ps`, `logs`, `exec`, `run`, `start`, `stop`, `restart`, `rm`, `images`, `volumes`, `stats`, `cp`, `export`, static `port`, `kill`, `version` |
| Present but blocked by [`apple/container`][apple-container] runtime gaps | `top`, `events`, dynamic `port` lookup, `port --index` values other than `1`, `pause`, `unpause`, `wait`, `stats --all`, `stats --no-trunc`, `cp --archive`, `cp --follow-link` |
| Present but blocked by `container-compose` design gaps | `exec --index` values other than `1`, `cp --index` values other than `1`, `export --index` values other than `1`, service-to-service `cp --all`, `watch`, `scale`, `attach`, `commit`, `publish` |

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
| [S1: Supported Local Web Stack](#s1-supported-local-web-stack) | Supported | Build, images, `create`, ports, static `port`, environment, one network, single-network MAC addresses, volume mounts, `volumes`, labels, `label_file`, lifecycle, logs, exec, stats, copy, and `down --volumes` |
| [A1: Apple Gap, Networking](#a1-apple-gap-networking) | [`apple/container`][apple-container] gap | Multiple networks, aliases, fixed IP attachment options, and network namespace modes |
| [A2: Apple Gap, Host Identity And Links](#a2-apple-gap-host-identity-and-links) | [`apple/container`][apple-container] gap | Hostname, domain name, explicit host entries, and legacy links |
| [A3: Apple Gap, Runtime Controls](#a3-apple-gap-runtime-controls) | [`apple/container`][apple-container] gap | Namespace controls, privileged/device access, advanced resources, and sysctls |
| [A4: Apple Gap, Health, Secrets, And Restart](#a4-apple-gap-health-secrets-and-restart) | [`apple/container`][apple-container] gap | Healthchecks, healthy/completed dependency gates, service secrets/configs, and restart policies |
| [A5: Apple Gap, Runtime Data Commands](#a5-apple-gap-runtime-data-commands) | [`apple/container`][apple-container] gap | Process listing, event streams, dynamic port lookup, pause/unpause, wait metadata, and stats output controls |
| [C1: Plugin Gap, Replica Scaling And Deploy](#c1-plugin-gap-replica-scaling-and-deploy) | `container-compose` gap | Replica naming, lifecycle, logs, `ps`, `rm`, `exec --index`, DNS, and deploy semantics |
| [C2: Plugin Gap, Advanced Build Fields](#c2-plugin-gap-advanced-build-fields) | `container-compose` gap | Additional contexts, inline Dockerfile, secrets, SSH, and provenance/SBOM fields |
| [C3: Plugin Gap, Develop, Providers, Models, And Hooks](#c3-plugin-gap-develop-providers-models-and-hooks) | `container-compose` gap | Watch/develop, providers, model bindings, and lifecycle hooks |
| [C4: Plugin Gap, Metadata, Storage, API Socket, And Pull Windows](#c4-plugin-gap-metadata-storage-api-socket-and-pull-windows) | `container-compose` gap | Dependency restart propagation, annotations, logging options, inherited mounts, API socket, block I/O, and time-window pull policy |
| [C5: Plugin Gap, Additional CLI Commands](#c5-plugin-gap-additional-cli-commands) | `container-compose` gap | Compose v2 commands that still need command-level plugin design |
| [O1: Config-Only Metadata](#o1-config-only-metadata) | Config-only | Extension metadata, top-level models/secrets, and `expose` in normalized output |

## Examples With Dockerfiles

### S1: Supported Local Web Stack

Expected result: `container compose config`, `container compose convert`, `build`, `create`, `up`, `ps`, `logs`, `exec`, `stats`, `cp`, `volumes`, `rm --force --volumes` for anonymous volumes, and `down --volumes` run through [`apple/container`][apple-container].

Status path:

- Docker Compose v2: accepts and normalizes this project.
- [`apple/container`][apple-container]: has the needed build, image, lifecycle, discovery, network, volume, log, exec, copy, and export primitives.
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
    tmpfs:
      - /run
    networks:
      - app
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

networks:
  app:
    labels:
      example.com/network: app

volumes:
  api-cache:
    labels:
      example.com/volume: cache
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
ARG APP_ENV=dev
RUN mkdir -p /app /cache /config && printf '%s\n' "$APP_ENV" > /app/env.txt
EXPOSE 8080
CMD ["sh", "-c", "sleep 3600"]
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
container compose config
container compose build
container compose create --build
container compose create --pull build api
container compose create --no-build worker
container compose up --pull missing
container compose up --no-deps api
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
container compose exec api sh
container compose exec -T api echo ok
container compose exec --interactive=false -T api echo ok
container compose exec -d api sleep 60
container compose exec -e DEBUG=1 api env
container compose exec -u 1000:1000 api id
container compose exec -w /app api pwd
container compose exec --index 1 api true
container compose stats
container compose stats --no-stream --format json api worker
container compose volumes
container compose volumes --format json api
container compose volumes --quiet worker
container compose cp api:/app/env.txt ./env.txt
container compose cp --all ./seed.sql api:/tmp/seed.sql
container compose export -o api.tar api
container compose port api 8080
container compose stop --timeout 12 api
container compose restart -t 12 api
container compose kill worker
container compose down --timeout 12 --volumes
container compose down --rmi local --timeout 12 --volumes
```

### A1: Apple Gap, Networking

Expected result: `container compose up` rejects this before creating resources because [`apple/container`][apple-container] needs multi-network attach/connect, per-network aliases/options beyond MAC, fixed addresses, and network namespace modes.

Status path:

- Docker Compose v2: accepts and normalizes these network attachments.
- [`apple/container`][apple-container]: missing multi-network attach/connect, per-network aliases/options beyond MAC, fixed addresses, and Docker-compatible namespace modes.
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
  app: {}
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

Expected result: `container compose up` rejects this because [`apple/container`][apple-container] needs namespace, advanced resource, privileged/device, and sysctl primitives. `container compose exec --privileged` is rejected because privileged exec processes need an [`apple/container`][apple-container] primitive.

Status path:

- Docker Compose v2: accepts and normalizes these runtime controls.
- [`apple/container`][apple-container]: missing the required namespace, privileged/device, advanced resource, sysctl, and privileged exec primitives.
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

Expected result: these commands and options reject because [`apple/container`][apple-container] needs richer runtime data and state controls. `container compose port` supports static published bindings, but dynamic host ports and replica indexes need runtime inspect data that [`apple/container`][apple-container] does not expose yet. Plain service-aware `container compose cp` is supported, but `cp --archive` and `cp --follow-link` reject until [`apple/container`][apple-container] exposes copy archive and symlink-follow controls.

Status path:

- Docker Compose v2: supports these commands.
- [`apple/container`][apple-container]: missing process listing, event streaming, runtime-discovered published-port lookup, pause/unpause, wait/exit metadata, stats all-container/truncation primitives, and copy archive/follow-link controls.
- `container-compose`: exposes the command names and reports the Apple runtime gap for requests that need runtime-discovered state.

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
container compose port api 8080
container compose pause api
container compose unpause api
container compose wait api
container compose stats --all
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

### C1: Plugin Gap, Replica Scaling And Deploy

Expected result: `container compose up` rejects this because `container-compose` still needs Compose replica naming, reconciliation, DNS, lifecycle, and deploy semantics beyond the supported local CPU/memory limits. `container compose exec --index 2` and `container compose cp --index 2` are rejected for the same reason.

Status path:

- Docker Compose v2: accepts and normalizes scaling and deploy metadata.
- [`apple/container`][apple-container]: not known to be the first blocker for this example.
- `container-compose`: maps `deploy.resources.limits.cpus` and `deploy.resources.limits.memory` to local runtime limits, but still needs multi-replica orchestration, naming, DNS, lifecycle, replica-aware `exec` and `cp`, service-to-service `cp --all`, and broader deploy semantics.

The equivalent CLI scaling form is also rejected with the same plugin gap:

```sh
container compose up --scale worker=3 worker
container compose exec --index 2 worker true
container compose cp --index 2 worker:/tmp/report.txt ./report.txt
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
```

Dockerfile: `worker/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

### C2: Plugin Gap, Advanced Build Fields

Expected result: `container compose build` rejects this before running `container build` because the advanced build fields need safe plugin mapping first.

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
        - npm_token
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

Expected result: `container compose up` rejects this because watch/develop, provider/model wiring, and lifecycle hooks need plugin orchestration.

Status path:

- Docker Compose v2: accepts and normalizes develop, provider, model, and hook fields.
- [`apple/container`][apple-container]: not known to be the first blocker for this example.
- `container-compose`: needs orchestration design for watch/sync/rebuild flows, service providers, model bindings, and hook execution.

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

### C4: Plugin Gap, Metadata, Storage, API Socket, And Pull Windows

Expected result: `container compose up` rejects this because annotations, logging/storage options, inherited mounts, API socket exposure, block I/O controls, and time-window pull policy need plugin implementation and security review.

Status path:

- Docker Compose v2: accepts and normalizes these service fields.
- [`apple/container`][apple-container]: not known to be the first blocker for this grouped example.
- `container-compose`: needs runtime mapping, inherited mount behavior, logging/storage policy, API socket security review, block I/O handling, and time-window pull semantics.

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
    annotations:
      example.com/owner: platform
    logging:
      driver: json-file
    pull_policy: daily
    volumes_from:
      - base
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

Expected result: these Docker Compose v2 commands are recognized by `container-compose` and fail with command-specific `container-compose` design gap messages.

Status path:

- Docker Compose v2: supports these commands.
- [`apple/container`][apple-container]: command-specific runtime availability still needs to be assessed as each command is implemented.
- `container-compose`: exposes these command names and reports the plugin design gap instead of failing as an unknown subcommand.

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
docker compose watch
docker compose scale worker=3
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
