# Compatibility

`container-compose` targets local-development Docker Compose v2 workflows where Apple's [`container`](https://github.com/apple/container) CLI exposes matching runtime primitives.

This file answers the question "why does this Compose v2 surface work or fail here?" by separating responsibility into three buckets:

1. Supported today because Docker Compose v2 accepts it, Apple [`container`](https://github.com/apple/container) has the runtime primitive, and [`stephenlclarke/container-compose`](https://github.com/stephenlclarke/container-compose) maps it with tests.
2. Not supported by Apple `container` because Docker Compose v2 accepts it, and this plugin recognizes it, but the Apple runtime/API primitive is missing or not rich enough yet.
3. Not supported by `container-compose` because Docker Compose v2 accepts it and Apple `container` is not known to be the first blocker, but this plugin has not implemented the orchestration yet.

If Docker Compose v2 rejects a file, `compose-go` rejects it during normalization before `container-compose` orchestration starts. The tables below cover Compose v2 surfaces that are valid or intentionally accepted by the normalizer.

## Reader Shortcut

| Question | Read |
| --- | --- |
| What works right now? | [Supported Today](#supported-today), then [S1](#s1-supported-local-web-stack). |
| What is blocked by Apple `container`? | [Not Supported By Apple `container`](#not-supported-by-apple-container), then the `A*` examples. |
| What is valid Compose but still needs plugin code? | [Not Supported By `container-compose`](#not-supported-by-container-compose), then the `C*` examples. |
| What is preserved for `config` but not applied at runtime? | [Config-Only Surfaces](#config-only-surfaces), then [O1](#o1-config-only-metadata). |
| Which Dockerfile or Compose example demonstrates a status? | [Example Index](#example-index). |

## References

- Compose file reference: [docs.docker.com/reference/compose-file](https://docs.docker.com/reference/compose-file/).
- Docker Compose v2 CLI reference: [docs.docker.com/reference/cli/docker/compose](https://docs.docker.com/reference/cli/docker/compose/).
- Docker Compose v2 implementation: [`docker/compose`](https://github.com/docker/compose).
- Docker Compose v2 Go API package: [`github.com/docker/compose/v2/pkg/api`](https://pkg.go.dev/github.com/docker/compose/v2/pkg/api).
- Compose model normalizer used here: [`compose-spec/compose-go`](https://github.com/compose-spec/compose-go).

## Status Ownership

| Status | Docker Compose v2 accepts it | Apple `container` has the runtime primitive | `container-compose` maps it | Owner to unblock | Runtime behavior |
| --- | --- | --- | --- | --- | --- |
| Supported | Yes | Yes | Yes | None | Runs through Apple `container`. |
| Apple `container` gap | Yes | No, or not rich enough yet | Recognized and rejected | Upstream [`apple/container`](https://github.com/apple/container) runtime/API work | Fails before side effects with an Apple runtime-gap message. |
| `container-compose` gap | Yes | Not known to be the first blocker | Not mapped yet | This repository | Fails before side effects with a plugin implementation-gap message. |
| Config-only | Yes | Not needed for config output | Preserved by `config`; ignored or rejected at runtime | Depends on service-level use | Visible in `config`; no runtime side effect by itself. |

The practical rule is:

- If a surface is an Apple `container` gap, this plugin should not emulate it
  with fragile behavior.
- If a surface is a `container-compose` gap, it needs design, implementation,
  and tests in this repository.
- If a surface is config-only, it can appear in `container compose config`
  without meaning `container compose up` will apply a runtime behavior.

## Compose V2 Feature Matrix

| Compose v2 surface | Current status | Owner to unblock if not supported | Example |
| --- | --- | --- | --- |
| File discovery, repeated `-f`, `.env`, `--env-file`, interpolation, merge, profiles, and `config` output | Supported | None | [S1](#s1-supported-local-web-stack), [O1](#o1-config-only-metadata) |
| `build.context`, `build.dockerfile`, `build.args`, `build.target`, `build.no_cache`, and CLI `--no-cache` | Supported | None | [S1](#s1-supported-local-web-stack) |
| Image pull, push, inspect, global `up --pull always/missing/never`, service `pull_policy: always/missing/if_not_present/never` | Supported | None | [S1](#s1-supported-local-web-stack) |
| `up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, `kill`, deterministic names, one-off names, config-hash recreate, orphan removal | Supported | None | [S1](#s1-supported-local-web-stack) |
| `ps`, `logs`, `exec`, `images`, service-aware `cp`, and `version` | Supported | None | [S1](#s1-supported-local-web-stack) |
| Project networks, external networks, one service network, and published ports | Supported | None | [S1](#s1-supported-local-web-stack) |
| Named volumes, bind mounts, tmpfs mounts, anonymous volumes, external volumes, read-only mounts, and `down --volumes` | Supported | None | [S1](#s1-supported-local-web-stack) |
| `command`, `entrypoint`, `working_dir`, `user`, `tty`, `stdin_open`, `read_only`, `init`, `platform`, `runtime`, `dns`, `dns_search`, `cap_add`, `cap_drop`, `mem_limit`, `cpus`, `shm_size`, `ulimits`, `stop_signal`, `stop_grace_period` | Supported | None | [S1](#s1-supported-local-web-stack) |
| Service environment, service env files, labels, project labels, service labels, one-off labels, config hash labels, working-directory labels, compose-file hash labels | Supported | None | [S1](#s1-supported-local-web-stack) |
| `depends_on` with no condition or `condition: service_started` | Supported | None | [S1](#s1-supported-local-web-stack) |
| Two or more networks on one service | Apple `container` gap | Upstream multi-network attachment and post-create network connect | [A1](#a1-apple-gap-networking) |
| Network aliases and attachment options such as `aliases`, `ipv4_address`, `ipv6_address`, `interface_name`, `gw_priority`, `driver_opts`, `priority`, and service-level network `mac_address` | Apple `container` gap | Upstream Compose-compatible network attachment options | [A1](#a1-apple-gap-networking) |
| `network_mode: host`, `none`, `service:...`, or `container:...` | Apple `container` gap | Upstream Docker-compatible network namespace modes | [A1](#a1-apple-gap-networking) |
| `hostname`, `domainname`, `extra_hosts`, service `mac_address`, `links`, and `external_links` | Apple `container` gap | Upstream host identity, explicit host entries, MAC address, and legacy link semantics | [A2](#a2-apple-gap-host-identity-and-links) |
| `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, and `isolation` | Apple `container` gap | Upstream namespace and isolation controls | [A3](#a3-apple-gap-runtime-controls) |
| `cpu_count`, `cpu_percent`, `cpu_period`, `cpu_quota`, `cpu_rt_period`, `cpu_rt_runtime`, `cpuset`, and `cpu_shares` | Apple `container` gap | Upstream CPU scheduler controls beyond supported `cpus` | [A3](#a3-apple-gap-runtime-controls) |
| `mem_reservation`, `memswap_limit`, `mem_swappiness`, `oom_kill_disable`, `oom_score_adj`, and `pids_limit` | Apple `container` gap | Upstream memory, OOM, swap, and PID controls beyond supported `mem_limit` | [A3](#a3-apple-gap-runtime-controls) |
| `group_add`, `security_opt`, `privileged`, `credential_spec`, `device_cgroup_rules`, `devices`, and `gpus` | Apple `container` gap | Upstream supplemental group, security, privileged, device, and GPU controls | [A3](#a3-apple-gap-runtime-controls) |
| `dns_opt` and `sysctls` | Apple `container` gap | Upstream DNS resolver options and per-container sysctls | [A3](#a3-apple-gap-runtime-controls) |
| `healthcheck`, `depends_on.condition: service_healthy`, and `depends_on.condition: service_completed_successfully` | Apple `container` gap | Upstream health status, exit code, and completion-time inspection | [A4](#a4-apple-gap-health-secrets-and-restart) |
| Service-level `configs` and `secrets` mounts | Apple `container` gap | Upstream Compose-style config and secret mount primitives | [A4](#a4-apple-gap-health-secrets-and-restart) |
| Service `restart` | Apple `container` gap | Upstream Docker-compatible restart policy | [A4](#a4-apple-gap-health-secrets-and-restart) |
| `top`, `events`, `port`, `pause`, `unpause`, and `wait` commands | Apple `container` gap | Upstream process listing, event stream, published-port inspect, pause/unpause, and wait/exit metadata | [A5](#a5-apple-gap-runtime-data-commands) |
| `scale` and `deploy.replicas` values other than `1` | `container-compose` gap | This repository | [C1](#c1-plugin-gap-replica-scaling) |
| Build fields beyond the supported subset, such as `additional_contexts`, cache import/export, build labels, platforms, secrets, SSH, tags, provenance, SBOM, build network, isolation, and entitlements | `container-compose` gap | This repository | [C2](#c2-plugin-gap-advanced-build-fields) |
| Compose Deploy Specification fields beyond local replica count | `container-compose` gap | This repository | [C1](#c1-plugin-gap-replica-scaling) |
| `develop` and watch settings | `container-compose` gap | This repository | [C3](#c3-plugin-gap-develop-metadata-providers-models-and-hooks) |
| Service `provider`, service `models`, `post_start`, and `pre_stop` | `container-compose` gap | This repository | [C3](#c3-plugin-gap-develop-metadata-providers-models-and-hooks) |
| `annotations`, `attach`, `label_file`, `logging`, and `storage_opt` | `container-compose` gap | This repository | [C3](#c3-plugin-gap-develop-metadata-providers-models-and-hooks) |
| `volumes_from` and service-level `volume_driver` | `container-compose` gap | This repository | [C4](#c4-plugin-gap-volume-shortcuts-api-socket-block-io-and-pull-policy) |
| `use_api_socket` | `container-compose` gap | This repository after security review | [C4](#c4-plugin-gap-volume-shortcuts-api-socket-block-io-and-pull-policy) |
| `blkio_config` | `container-compose` gap | This repository | [C4](#c4-plugin-gap-volume-shortcuts-api-socket-block-io-and-pull-policy) |
| Service `pull_policy` values such as `build`, `daily`, `weekly`, or duration windows | `container-compose` gap | This repository | [C4](#c4-plugin-gap-volume-shortcuts-api-socket-block-io-and-pull-policy) |
| Commands not listed as supported, including `create`, `ls`, `watch`, `stats`, `scale`, `attach`, `commit`, `convert`, `export`, `publish`, and `volumes` | `container-compose` gap | This repository | [C5](#c5-plugin-gap-additional-cli-commands) |
| Service `expose` | Config-only | None unless host publishing behavior is requested | [O1](#o1-config-only-metadata) |
| Top-level and service `x-*` extension fields | Config-only | None unless an extension is given runtime meaning | [O1](#o1-config-only-metadata) |
| Top-level `configs`, `secrets`, and `models` definitions | Config-only until a service consumes them | Apple `container` for config/secret mounts; this repository for model bindings | [O1](#o1-config-only-metadata) |

## Supported Today

These surfaces are supported because both layers have the necessary behavior:
Apple `container` exposes a compatible primitive, and `container-compose` maps
the Compose v2 surface to it.

| Surface group | Compose fields or commands | Apple `container` primitive used |
| --- | --- | --- |
| Normalize and print config | File discovery, `-f`, `.env`, `--env-file`, profiles, merge, interpolation, `config` | No runtime primitive needed; `compose-go` normalizes the model. |
| Build images | `build.context`, `build.dockerfile`, `build.args`, `build.target`, `build.no_cache`, `build --no-cache` | `container build` |
| Manage images | `pull`, `push`, `images`, `up --pull`, supported service `pull_policy` values | `container image pull`, `container image push`, `container image inspect`, `container image list` |
| Manage containers | `up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, `kill` | `container run`, `container start`, `container stop`, `container delete`, `container kill`, `container inspect`, `container list` |
| Interact with containers | `ps`, `logs`, `exec`, service-aware `cp` | `container list`, `container logs`, `container exec`, `container cp` |
| Basic networking | One service network, project networks, external networks, published ports | `container network create`, `container network delete`, `container run --network`, `container run --publish` |
| Basic storage | Named volumes, bind mounts, tmpfs mounts, anonymous volumes, external volumes, read-only mounts, `down --volumes` | `container volume create`, `container volume delete`, `container run --volume`, `container run --tmpfs` |
| Runtime options | Process, user, TTY, stdin, read-only, init, platform, runtime, DNS, capabilities, CPU, memory, shared memory, ulimits, stop signal, stop grace period | `container run` and `container stop` flags |
| Project metadata | Service labels and Compose lifecycle labels | Resource and container label flags |
| Simple ordering | Empty `depends_on` condition or `condition: service_started` | Orchestrator dependency ordering before `container run` |

## Not Supported By Apple `container`

These surfaces are valid Docker Compose v2 and are recognized by
`container-compose`, but runtime behavior depends on Apple `container`
capabilities that are not available in the baseline tracked by this repository.
The plugin rejects these before creating resources.

| Surface group | Compose fields or commands | Missing Apple `container` behavior |
| --- | --- | --- |
| Multi-network services | Two or more service `networks` entries | Post-create network connect and multi-network attachment |
| Rich network attachments | `aliases`, `driver_opts`, `gw_priority`, `interface_name`, `ipv4_address`, `ipv6_address`, `link_local_ips`, service-level network `mac_address`, `priority` | Compose-compatible aliases and per-network attachment options |
| Network namespace modes | `network_mode` values such as `host`, `none`, `service:api`, `container:name` | Docker-compatible network namespace selection |
| Host identity and host table | `hostname`, `domainname`, `extra_hosts`, service `mac_address` | Hostname/domain controls, explicit host entries, and MAC address controls |
| Legacy links | `links`, `external_links` | Legacy alias/link behavior and host-entry semantics |
| Namespace and isolation controls | `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, `isolation` | Namespace selection and parent cgroup controls |
| Advanced CPU controls | `cpu_count`, `cpu_percent`, `cpu_period`, `cpu_quota`, `cpu_rt_period`, `cpu_rt_runtime`, `cpuset`, `cpu_shares` | CPU scheduler controls beyond supported `cpus` |
| Advanced memory and process controls | `mem_reservation`, `memswap_limit`, `mem_swappiness`, `oom_kill_disable`, `oom_score_adj`, `pids_limit` | Resource controls beyond supported `mem_limit` |
| User, security, and device controls | `group_add`, `security_opt`, `privileged`, `credential_spec`, `device_cgroup_rules`, `devices`, `gpus` | Supplemental groups, security options, privileged mode, Windows credential specs, host devices, cgroup device rules, and GPU requests |
| DNS and kernel tuning | `dns_opt`, `sysctls` | DNS resolver options and per-container sysctls |
| Health and completion gates | `healthcheck`, `depends_on.condition: service_healthy`, `depends_on.condition: service_completed_successfully` | Health status, exit code, and completion-time inspection |
| Config and secret mounts | Service-level `configs`, service-level `secrets` | Compose-style config and secret mount primitives |
| Restart policy | Service `restart` | Docker-compatible automatic restart policies |
| Runtime data commands | `top`, `events`, `port`, `pause`, `unpause`, `wait` | Process listing, event stream, published-port inspect output, pause/unpause, wait, exit code, and completion metadata |

## Not Supported By `container-compose`

These surfaces are valid Docker Compose v2, but the missing work is in this
repository. They remain rejected until the plugin has design, implementation,
and tests.

| Surface group | Compose fields or commands | Missing plugin work |
| --- | --- | --- |
| Replica scaling | `scale`, `deploy.replicas` values other than `1` | Multi-replica naming, reconciliation, logs, `ps`, `rm`, DNS, and lifecycle behavior |
| Advanced build fields | `additional_contexts`, cache import/export, build labels, platforms, secrets, SSH, tags, provenance, SBOM, network, isolation, entitlements, and related build fields | Translation to safe `container build` behavior |
| Compose Deploy Specification | `deploy` fields beyond local replica count | Local interpretation or explicit non-support for mode, placement, update, rollback, endpoint, labels, restart policy, limits, and reservations |
| Develop/watch workflow | `develop`, `watch` | File watching, sync, rebuild, debounce, and reconcile orchestration |
| Providers, models, and hooks | Service `provider`, service `models`, `post_start`, `pre_stop` | Orchestration design and safety rules |
| Service metadata and logging | `annotations`, `attach`, `label_file`, `logging`, `storage_opt` | Runtime mapping and command behavior |
| Volume inheritance and driver shortcuts | `volumes_from`, service-level `volume_driver` | Inherited mount behavior and driver semantics |
| API socket mounting | `use_api_socket` | Security review and explicit mount policy |
| Block I/O controls | `blkio_config` | Runtime argument mapping and validation |
| Extra pull policies | `pull_policy: build`, `daily`, `weekly`, or duration windows | Time-window and build-trigger semantics |
| Additional CLI commands | `create`, `ls`, `watch`, `stats`, `scale`, `attach`, `commit`, `convert`, `export`, `publish`, `volumes` | Command design and runtime mapping |

## Config-Only Surfaces

These surfaces are normalized and preserved because they are useful in
`container compose config` output or harmless as metadata, but they do not
currently change runtime orchestration by themselves.

| Surface | Current behavior |
| --- | --- |
| Service `expose` | Preserved in config; no host publishing is performed. Use `ports` for host publishing. |
| Top-level and service `x-*` extension fields | Preserved in config; ignored by runtime unless future plugin behavior gives a specific extension meaning. |
| Top-level `configs` and `secrets` definitions | Preserved in config. Service-level use is rejected because mounting needs Apple runtime support. |
| Top-level `models` definitions | Preserved in config. Service-level model bindings are rejected because runtime model wiring is a plugin gap. |

## Example Index

Each example includes a `compose.yaml` snippet and a Dockerfile for every
service that declares `build:`. Command-only gaps reuse the supported S1 project
because the gap is in the command surface, not the Dockerfile content.

| Example | Status bucket | What it demonstrates |
| --- | --- | --- |
| [S1: Supported Local Web Stack](#s1-supported-local-web-stack) | Supported today | Build, image tags, ports, environment, one network, volumes, limits, labels, lifecycle commands, logs, exec, copy, and `down --volumes`. |
| [A1: Apple Gap, Networking](#a1-apple-gap-networking) | Not supported by Apple `container` | Multiple networks, aliases, fixed IP attachment options, and namespace network modes. |
| [A2: Apple Gap, Host Identity And Links](#a2-apple-gap-host-identity-and-links) | Not supported by Apple `container` | Hostname, domain name, explicit host entries, MAC address, and legacy links. |
| [A3: Apple Gap, Runtime Controls](#a3-apple-gap-runtime-controls) | Not supported by Apple `container` | Namespace controls, privileged/device access, advanced resource controls, DNS options, and sysctls. |
| [A4: Apple Gap, Health, Secrets, And Restart](#a4-apple-gap-health-secrets-and-restart) | Not supported by Apple `container` | Healthchecks, healthy/completed dependency gates, service secrets, and restart policies. |
| [A5: Apple Gap, Runtime Data Commands](#a5-apple-gap-runtime-data-commands) | Not supported by Apple `container` | Process listing, event streams, port lookup, pause/unpause, and wait metadata. |
| [C1: Plugin Gap, Replica Scaling](#c1-plugin-gap-replica-scaling) | Not supported by `container-compose` | Multi-replica naming, lifecycle, logs, `ps`, `rm`, and DNS behavior. |
| [C2: Plugin Gap, Advanced Build Fields](#c2-plugin-gap-advanced-build-fields) | Not supported by `container-compose` | Additional build contexts, build cache wiring, build secrets, and SSH forwarding. |
| [C3: Plugin Gap, Develop, Metadata, Providers, Models, And Hooks](#c3-plugin-gap-develop-metadata-providers-models-and-hooks) | Not supported by `container-compose` | Watch/develop, provider/model bindings, lifecycle hooks, annotations, label files, and logging options. |
| [C4: Plugin Gap, Volume Shortcuts, API Socket, Block I/O, And Pull Policy](#c4-plugin-gap-volume-shortcuts-api-socket-block-io-and-pull-policy) | Not supported by `container-compose` | Inherited mounts, API socket exposure, block I/O controls, and time-window pull policy. |
| [C5: Plugin Gap, Additional CLI Commands](#c5-plugin-gap-additional-cli-commands) | Not supported by `container-compose` | Valid Compose v2 commands that still need command-level plugin design. |
| [O1: Config-Only Metadata](#o1-config-only-metadata) | Config-only | Extension metadata, top-level models/secrets, and `expose` in normalized output. |

## Examples With Dockerfiles

Every example includes a `compose.yaml` plus the `Dockerfile` for each service
that declares `build:`. The Dockerfiles are deliberately small so the Compose
surface, not image complexity, determines the status.

### S1: Supported Local Web Stack

This project uses only surfaces supported by both `container-compose` and Apple
`container`: build, image tagging, ports, environment, one network, one named
volume, CPU/memory limits, stop behavior, and simple `service_started`
dependency ordering.

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
    ports:
      - "8080:8080"
    volumes:
      - api-cache:/cache
    networks:
      - app
    depends_on:
      worker:
        condition: service_started
    cpus: "1.5"
    mem_limit: 256m
    stop_signal: SIGTERM
    stop_grace_period: 10s

  worker:
    build:
      context: ./worker
    command: ["sh", "-c", "while true; do echo worker; sleep 30; done"]
    networks:
      - app

networks:
  app: {}

volumes:
  api-cache: {}
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
ARG APP_ENV=dev
RUN mkdir -p /app /cache && printf '%s\n' "$APP_ENV" > /app/env.txt
EXPOSE 8080
CMD ["sh", "-c", "sleep 3600"]
```

Dockerfile: `worker/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

Useful supported commands against this project include:

```sh
container compose config
container compose build
container compose up --pull missing
container compose ps
container compose logs api
container compose exec api sh
container compose cp api:/app/env.txt ./env.txt
container compose down --volumes
```

### A1: Apple Gap, Networking

This project is valid Docker Compose v2, but it needs multiple network
attachments, aliases, fixed IP attachment options, and network namespace modes.
`container compose up` rejects it before creating resources because Apple
`container` does not expose compatible network behavior yet.

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
  admin:
    ipam:
      config:
        - subnet: 10.10.0.0/24
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

This project is valid Docker Compose v2, but hostname/domain, explicit host
entries, MAC address, and legacy link semantics need runtime support that Apple
`container` does not expose yet.

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

This project is valid Docker Compose v2, but namespace selection,
privileged/device access, advanced CPU/memory controls, DNS resolver options,
and sysctls require Apple `container` runtime primitives that are not available
yet.

```yaml
# compose.yaml
name: apple-runtime-gap-demo

services:
  api:
    build:
      context: ./api
    pid: host
    ipc: host
    privileged: true
    devices:
      - "/dev/fuse:/dev/fuse"
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

This project is valid Docker Compose v2, but the health gate,
successful-completion dependency, secret mount, and restart policy need Apple
runtime primitives first.

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

These commands are valid Docker Compose v2 workflows, but they need richer
runtime data from Apple `container`: process lists, event streams,
published-port inspection, pause/unpause, and exit/completion metadata. Use the
[S1](#s1-supported-local-web-stack) Dockerfiles to create a project, then run:

```sh
container compose top api
container compose events --json
container compose port api 8080
container compose pause api
container compose unpause api
container compose wait api
```

### C1: Plugin Gap, Replica Scaling

This project is valid Docker Compose v2, and Apple `container` can create
multiple containers in general, but `container-compose` does not yet implement
Compose replica naming, lifecycle, logs, `ps`, `rm`, or DNS semantics.

```yaml
# compose.yaml
name: plugin-scale-gap-demo

services:
  worker:
    build:
      context: ./worker
    deploy:
      replicas: 3
```

Dockerfile: `worker/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

### C2: Plugin Gap, Advanced Build Fields

This project is valid Docker Compose v2, but build cache wiring, additional
contexts, build secrets, and SSH forwarding need explicit plugin mapping before
any `container build` command can safely run.

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

### C3: Plugin Gap, Develop, Metadata, Providers, Models, And Hooks

This project is valid Docker Compose v2, but file watching, service providers,
service-level model bindings, lifecycle hooks, annotations, label files, and
logging options need plugin orchestration and safety rules before they can run.

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
    annotations:
      example.com/owner: platform
    label_file:
      - ./labels.env
    logging:
      driver: json-file
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

### C4: Plugin Gap, Volume Shortcuts, API Socket, Block I/O, And Pull Policy

This project is valid Docker Compose v2, but inherited mounts, API socket
exposure, block I/O controls, and time-window pull policies need plugin
implementation and security review.

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

These Docker Compose v2 commands need command-level design and runtime mapping
inside `container-compose`. Use the [S1](#s1-supported-local-web-stack)
Dockerfiles to create a project, then compare the missing command behavior:

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

### O1: Config-Only Metadata

This project keeps extension metadata, top-level model metadata, top-level
secret metadata, and `expose` in config output. Runtime startup ignores harmless
metadata and does not publish `expose` to the host.

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

When a change adds, removes, or changes a Compose-to-`container` runtime
mapping, update this file in the same commit or pull request. Do not mark a
primitive as supported until the orchestrator maps it, rejects unsupported
alternatives clearly, and has focused test coverage.
