# Compatibility

`container-compose` targets local-development Docker Compose v2 workflows where Apple's [`container`](https://github.com/apple/container) CLI exposes matching runtime primitives.

This file separates three different questions that are easy to blur together:

- Does Docker Compose v2 accept and normalize the Compose file?
- Does Apple [`container`](https://github.com/apple/container) expose the runtime primitive needed to run it?
- Does [`stephenlclarke/container-compose`](https://github.com/stephenlclarke/container-compose) map that normalized model to Apple `container` commands?

Unsupported runtime features are rejected before resources are created. Harmless metadata can still appear in `container compose config` without implying that `container compose up` applies runtime behavior.

## How To Read This File

Read every row as a three-step chain:

1. Docker Compose v2 accepts and normalizes the Compose file.
2. Apple [`container`](https://github.com/apple/container) has a runtime primitive that can perform the behavior.
3. `container-compose` maps the normalized Compose model to Apple `container` commands.

The first unsupported step owns the gap.

| Bucket | Docker Compose v2 | Apple `container` | `container-compose` | What happens today | Fix owner |
| --- | --- | --- | --- | --- | --- |
| Supported | Accepts the surface | Has a matching primitive | Maps it | Runtime commands execute through Apple `container` | No compatibility fix needed |
| Apple `container` gap | Accepts the surface | Missing, incomplete, or not exposed | Detects the field and rejects it | Fails before resources are created with an `apple/container` runtime gap message | Upstream [`apple/container`](https://github.com/apple/container), then this repo maps the new primitive |
| `container-compose` gap | Accepts the surface | Not known to be the first blocker | Does not map it yet | Fails before resources are created with a `container-compose` implementation message | This repository |
| Config-only | Accepts the surface | Not needed for `config` output | Preserves it for `config` | Appears in normalized output; runtime commands ignore harmless metadata or reject service-level use | Depends on the runtime behavior requested later |

## Support Matrix

### Supported By Apple `container` And `container-compose`

These surfaces have all three pieces: Docker Compose v2 model support, Apple `container` runtime support, and plugin orchestration.

| Compose v2 surface | Supported subset | Apple `container` primitive used | Example |
| --- | --- | --- | --- |
| Config normalization | File discovery, repeated `-f`, `.env`, `--env-file`, interpolation, merge, profiles, `--project-directory`, `-p/--project-name`, and canonical `config` JSON | No runtime primitive; `compose-go` normalizes the Compose model | [S1](#s1-supported-local-web-stack), [O1](#o1-config-only-metadata) |
| Build and images | `build.context`, `build.dockerfile`, `build.args`, `build.target`, `build.no_cache`, CLI `build --no-cache`, `pull`, `push`, `images`, global `up --pull always/missing/never`, service `pull_policy: always/missing/if_not_present/never` | `container build`, `container image pull`, `container image push`, `container image inspect`, `container image list` | [S1](#s1-supported-local-web-stack) |
| Container lifecycle | `up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, `kill`, deterministic names, one-off names, config-hash recreate, `--force-recreate`, `--no-recreate`, `--remove-orphans` | `container run`, `container start`, `container stop`, `container delete`, `container kill`, `container inspect`, `container list` | [S1](#s1-supported-local-web-stack) |
| Container interaction | `ps`, `logs`, `exec`, service-aware `cp`, `version` | `container list`, `container logs`, `container exec`, `container cp`, plugin version output | [S1](#s1-supported-local-web-stack) |
| Default networking | One service network, default project networks, external networks, service ports | `container network create`, `container network delete`, `container run --network`, `container run --publish` | [S1](#s1-supported-local-web-stack) |
| Default storage | Named volumes, external volumes, bind mounts, anonymous volumes, read-only mounts, tmpfs mounts, `down --volumes` | `container volume create`, `container volume delete`, `container run --volume`, `container run --tmpfs` | [S1](#s1-supported-local-web-stack) |
| Common runtime options | `command`, `entrypoint`, `container_name`, `working_dir`, `user`, `tty`, `stdin_open`, `read_only`, `init`, `platform`, `runtime`, `dns`, `dns_search`, `cap_add`, `cap_drop`, `cpus`, `mem_limit`, `shm_size`, `ulimits`, `stop_signal`, `stop_grace_period` | `container run` and `container stop` flags | [S1](#s1-supported-local-web-stack) |
| Environment and labels | Service `environment`, `env_file`, service labels, network labels, volume labels, Compose project/service/config-hash labels | `container run --env`, `container run --env-file`, resource/container labels | [S1](#s1-supported-local-web-stack) |
| Simple ordering | `depends_on` with no condition or `condition: service_started` | Plugin dependency ordering before `container run` | [S1](#s1-supported-local-web-stack) |

### Blocked By Apple `container`

These are valid Docker Compose v2 surfaces. `container-compose` recognizes them, but Apple `container` does not expose a Docker Compose compatible runtime primitive yet.

| Compose v2 surface | Examples of fields or commands | Missing Apple `container` primitive | Example |
| --- | --- | --- | --- |
| Rich network attachment | Multiple service networks, `aliases`, `driver_opts`, `gw_priority`, `interface_name`, `ipv4_address`, `ipv6_address`, `link_local_ips`, per-network `mac_address`, `priority`, `network_mode` | Multi-network attach/connect, per-network aliases/options, fixed addresses, Docker-compatible namespace modes | [A1](#a1-apple-gap-networking) |
| Host identity and legacy links | `hostname`, `domainname`, `extra_hosts`, service `mac_address`, `links`, `external_links` | Hostname/domain controls, explicit host entries, MAC controls, legacy link/alias semantics | [A2](#a2-apple-gap-host-identity-and-links) |
| Namespace and resource controls | `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, `isolation`, advanced CPU controls, advanced memory/OOM/PID controls | Namespace selection, parent cgroups, CPU scheduler controls beyond `cpus`, memory controls beyond `mem_limit`, swap/OOM/PID controls | [A3](#a3-apple-gap-runtime-controls) |
| User, security, devices, DNS, kernel tuning | `group_add`, `security_opt`, `privileged`, `credential_spec`, `device_cgroup_rules`, `devices`, `gpus`, `dns_opt`, `sysctls` | Supplemental groups, security profiles, privileged mode, host devices, GPUs, DNS resolver options, per-container sysctls | [A3](#a3-apple-gap-runtime-controls) |
| Health, completion, configs, secrets, restart | `healthcheck`, `depends_on.condition: service_healthy`, `depends_on.condition: service_completed_successfully`, service-level `configs`, service-level `secrets`, service `restart` | Health status, exit code/completion-time metadata, config/secret mount primitives, restart policy support | [A4](#a4-apple-gap-health-secrets-and-restart) |
| Runtime data and state commands | `top`, `events`, `port`, `pause`, `unpause`, `wait` | Process listing, event stream, published-port inspect, pause/unpause, wait/exit metadata | [A5](#a5-apple-gap-runtime-data-commands) |

### Blocked By `container-compose`

These are valid Docker Compose v2 surfaces where Apple `container` is not known to be the first blocker. The missing design, orchestration, or safety policy belongs in this repository.

| Compose v2 surface | Examples of fields or commands | Missing plugin work | Example |
| --- | --- | --- | --- |
| Replica scaling and local deploy handling | `scale`, `deploy.replicas` values other than `1`, `deploy` fields beyond local replica count | Multi-replica naming, reconciliation, DNS behavior, logs, `ps`, removal, and a local interpretation of deploy mode/placement/update/rollback/endpoint/labels/restart/resources | [C1](#c1-plugin-gap-replica-scaling-and-deploy) |
| Advanced build configuration | `additional_contexts`, `cache_from`, `cache_to`, `dockerfile_inline`, `entitlements`, build `extra_hosts`, build `isolation`, build `labels`, build `network`, `platforms`, build `privileged`, `provenance`, build `pull`, `sbom`, build `secrets`, build `shm_size`, `ssh`, `tags`, build `ulimits` | Safe translation to `container build` behavior and tests | [C2](#c2-plugin-gap-advanced-build-fields) |
| Develop, providers, models, hooks | `develop`, watch settings, service `provider`, service `models`, `post_start`, `pre_stop` | Watch/sync/rebuild orchestration, provider/model wiring, lifecycle hook safety and ordering | [C3](#c3-plugin-gap-develop-providers-models-and-hooks) |
| Metadata, logging, storage shortcuts | `annotations`, `attach`, `label_file`, `logging`, `log_driver`, `log_opt`, `storage_opt`, `volumes_from`, service-level `volume_driver` | Runtime mapping, inherited mount behavior, label-file loading, logging behavior, storage option policy | [C4](#c4-plugin-gap-metadata-storage-api-socket-and-pull-windows) |
| API socket, block I/O, pull windows | `use_api_socket`, `blkio_config`, service `pull_policy: build/daily/weekly/<duration>` | Security review, resource-control mapping, and time-window/build-trigger pull semantics | [C4](#c4-plugin-gap-metadata-storage-api-socket-and-pull-windows) |
| Additional CLI commands | `create`, `ls`, `watch`, `stats`, `scale`, `attach`, `commit`, `convert`, `export`, `publish`, `volumes` | Command design, output compatibility, and runtime mapping | [C5](#c5-plugin-gap-additional-cli-commands) |

### Config-Only Today

These Compose surfaces are useful in normalized output, but they do not currently change runtime orchestration.

| Compose v2 surface | Current behavior | Example |
| --- | --- | --- |
| Top-level and service `x-*` extensions | Preserved by `container compose config`; no runtime behavior by itself | [O1](#o1-config-only-metadata) |
| Service `expose` | Preserved by `config`; it does not publish host ports. Use `ports` for host publishing | [O1](#o1-config-only-metadata) |
| Top-level `configs` and `secrets` definitions | Preserved by `config`; service-level consumption is an Apple `container` gap because mounts need runtime support | [O1](#o1-config-only-metadata), [A4](#a4-apple-gap-health-secrets-and-restart) |
| Top-level `models` definitions | Preserved by `config`; service-level model bindings are a plugin gap | [O1](#o1-config-only-metadata), [C3](#c3-plugin-gap-develop-providers-models-and-hooks) |

## CLI Command Status

| Status | Commands |
| --- | --- |
| Supported | `config`, `up`, `down`, `build`, `pull`, `push`, `ps`, `logs`, `exec`, `run`, `start`, `stop`, `restart`, `rm`, `images`, `cp`, `kill`, `version` |
| Present but blocked by Apple `container` runtime gaps | `top`, `events`, `port`, `pause`, `unpause`, `wait` |
| Not implemented by `container-compose` yet | `create`, `ls`, `watch`, `stats`, `scale`, `attach`, `commit`, `convert`, `export`, `publish`, `volumes` |

## References

- Compose file reference: [docs.docker.com/reference/compose-file](https://docs.docker.com/reference/compose-file/).
- Docker Compose v2 CLI reference: [docs.docker.com/reference/cli/docker/compose](https://docs.docker.com/reference/cli/docker/compose/).
- Docker Compose v2 implementation: [`docker/compose`](https://github.com/docker/compose).
- Docker Compose v2 Go API package: [`github.com/docker/compose/v2/pkg/api`](https://pkg.go.dev/github.com/docker/compose/v2/pkg/api).
- Compose model normalizer used here: [`compose-spec/compose-go`](https://github.com/compose-spec/compose-go).

## Example Index

Every example includes a Compose file or commands plus the matching Dockerfile snippets needed to try the surface in an isolated scratch directory.

| Example | Status bucket | What it demonstrates |
| --- | --- | --- |
| [S1: Supported Local Web Stack](#s1-supported-local-web-stack) | Supported | Build, images, ports, environment, one network, volumes, labels, lifecycle, logs, exec, copy, and `down --volumes` |
| [A1: Apple Gap, Networking](#a1-apple-gap-networking) | Apple `container` gap | Multiple networks, aliases, fixed IP attachment options, and network namespace modes |
| [A2: Apple Gap, Host Identity And Links](#a2-apple-gap-host-identity-and-links) | Apple `container` gap | Hostname, domain name, explicit host entries, MAC address, and legacy links |
| [A3: Apple Gap, Runtime Controls](#a3-apple-gap-runtime-controls) | Apple `container` gap | Namespace controls, privileged/device access, advanced resources, DNS options, and sysctls |
| [A4: Apple Gap, Health, Secrets, And Restart](#a4-apple-gap-health-secrets-and-restart) | Apple `container` gap | Healthchecks, healthy/completed dependency gates, service secrets/configs, and restart policies |
| [A5: Apple Gap, Runtime Data Commands](#a5-apple-gap-runtime-data-commands) | Apple `container` gap | Process listing, event streams, port lookup, pause/unpause, and wait metadata |
| [C1: Plugin Gap, Replica Scaling And Deploy](#c1-plugin-gap-replica-scaling-and-deploy) | `container-compose` gap | Replica naming, lifecycle, logs, `ps`, `rm`, DNS, and deploy semantics |
| [C2: Plugin Gap, Advanced Build Fields](#c2-plugin-gap-advanced-build-fields) | `container-compose` gap | Additional contexts, cache, inline Dockerfile, secrets, SSH, tags, and provenance/SBOM fields |
| [C3: Plugin Gap, Develop, Providers, Models, And Hooks](#c3-plugin-gap-develop-providers-models-and-hooks) | `container-compose` gap | Watch/develop, providers, model bindings, and lifecycle hooks |
| [C4: Plugin Gap, Metadata, Storage, API Socket, And Pull Windows](#c4-plugin-gap-metadata-storage-api-socket-and-pull-windows) | `container-compose` gap | Annotations, label files, logging options, inherited mounts, API socket, block I/O, and time-window pull policy |
| [C5: Plugin Gap, Additional CLI Commands](#c5-plugin-gap-additional-cli-commands) | `container-compose` gap | Compose v2 commands that still need command-level plugin design |
| [O1: Config-Only Metadata](#o1-config-only-metadata) | Config-only | Extension metadata, top-level models/secrets, and `expose` in normalized output |

## Examples With Dockerfiles

### S1: Supported Local Web Stack

Expected result: `container compose config`, `build`, `up`, `ps`, `logs`, `exec`, `cp`, and `down --volumes` run through Apple `container`.

Status path:

- Docker Compose v2: accepts and normalizes this project.
- Apple `container`: has the needed build, image, lifecycle, network, volume, log, exec, and copy primitives.
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
      args:
        APP_ENV: dev
    image: example/api:dev
    pull_policy: missing
    command: ["sh", "-c", "printf 'ready\n'; sleep 3600"]
    environment:
      API_MODE: local
    env_file:
      - ./api.env
    ports:
      - "8080:8080"
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
    shm_size: 64m
    init: true
    stop_signal: SIGTERM
    stop_grace_period: 10s
    labels:
      example.com/service: api

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

Dockerfile: `worker/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

Useful supported commands against this project:

```sh
container compose config
container compose build
container compose up --pull missing
container compose ps
container compose logs api
container compose exec api sh
container compose cp api:/app/env.txt ./env.txt
container compose kill worker
container compose down --volumes
```

### A1: Apple Gap, Networking

Expected result: `container compose up` rejects this before creating resources because Apple `container` needs multi-network attach/connect, per-network aliases/options, fixed addresses, and network namespace modes.

Status path:

- Docker Compose v2: accepts and normalizes these network attachments.
- Apple `container`: missing multi-network attach/connect, per-network aliases/options, fixed addresses, and Docker-compatible namespace modes.
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

Expected result: `container compose up` rejects this because Apple `container` needs host identity, explicit host-entry, MAC address, and link semantics.

Status path:

- Docker Compose v2: accepts and normalizes host identity and legacy link fields.
- Apple `container`: missing hostname/domain controls, explicit host-entry support, MAC address controls, and legacy link semantics.
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
    mac_address: "02:42:ac:11:00:03"
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

Expected result: `container compose up` rejects this because Apple `container` needs namespace, advanced resource, privileged/device, DNS option, and sysctl primitives.

Status path:

- Docker Compose v2: accepts and normalizes these runtime controls.
- Apple `container`: missing the required namespace, privileged/device, advanced resource, DNS option, and sysctl primitives.
- `container-compose`: detects those fields and reports the Apple runtime gap.

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
    dns_opt:
      - use-vc
    sysctls:
      net.ipv4.ip_local_port_range: "1024 65000"
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

### A4: Apple Gap, Health, Secrets, And Restart

Expected result: `container compose up` rejects this because Apple `container` needs health status, completion metadata, config/secret mounts, and restart policies.

Status path:

- Docker Compose v2: accepts and normalizes healthchecks, dependency conditions, configs, secrets, and restart policies.
- Apple `container`: missing health status, exit/completion metadata, config/secret mount primitives, and restart policy support.
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

Expected result: these commands reject because Apple `container` needs richer runtime data and state controls.

Status path:

- Docker Compose v2: supports these commands.
- Apple `container`: missing process listing, event streaming, published-port lookup, pause/unpause, and wait/exit metadata primitives.
- `container-compose`: exposes the command names but reports the Apple runtime gap.

```yaml
# compose.yaml
name: apple-command-gap-demo

services:
  api:
    build:
      context: ./api
    ports:
      - "8080:8080"

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

Expected result: `container compose up` rejects this because `container-compose` still needs Compose replica naming, reconciliation, DNS, lifecycle, and deploy semantics.

Status path:

- Docker Compose v2: accepts and normalizes scaling and deploy metadata.
- Apple `container`: not known to be the first blocker for this example.
- `container-compose`: needs multi-replica orchestration, naming, DNS, lifecycle, and deploy semantics.

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
- Apple `container`: not known to be the first blocker for this example.
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
      cache_from:
        - type=registry,ref=example/api:cache
      secrets:
        - npm_token
      ssh:
        - default
      tags:
        - example/api:dev

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
- Apple `container`: not known to be the first blocker for this example.
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

Expected result: `container compose up` rejects this because annotations, label files, logging/storage options, inherited mounts, API socket exposure, block I/O controls, and time-window pull policy need plugin implementation and security review.

Status path:

- Docker Compose v2: accepts and normalizes these service fields.
- Apple `container`: not known to be the first blocker for this grouped example.
- `container-compose`: needs runtime mapping, inherited mount behavior, label-file loading, logging/storage policy, API socket security review, block I/O handling, and time-window pull semantics.

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
    annotations:
      example.com/owner: platform
    label_file:
      - ./labels.env
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

Expected result: these Docker Compose v2 commands need command-level design and runtime mapping inside `container-compose`.

Status path:

- Docker Compose v2: supports these commands.
- Apple `container`: command-specific runtime availability still needs to be assessed as each command is implemented.
- `container-compose`: does not implement these command surfaces yet.

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
docker compose create
docker compose ls
docker compose watch
docker compose stats
docker compose scale worker=3
docker compose attach api
docker compose commit api example/api:snapshot
docker compose convert
docker compose export api
docker compose publish
docker compose volumes
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
- Apple `container`: no primitive is required for read-only `config` output.
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

When a change adds, removes, or changes a Compose-to-`container` runtime mapping, update this file in the same commit or pull request. Do not mark a primitive as supported until the orchestrator maps it, unsupported alternatives fail clearly, and focused tests cover the behavior.
