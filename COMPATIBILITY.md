# Compatibility

`container-compose` targets local-development Docker Compose v2 workflows where Apple's [`container`](https://github.com/apple/container) CLI exposes matching runtime primitives.

This page separates three different compatibility questions that are easy to blur
together:

| Question | Answered by |
| --- | --- |
| Does Docker Compose v2 define the surface? | The Compose file and Docker Compose CLI references. |
| Does Apple `container` expose the matching runtime primitive? | The current [`apple/container`](https://github.com/apple/container) command/API surface and the runtime-gap validators in this repository. |
| Does `stephenlclarke/container-compose` map that primitive safely? | The orchestrator, CLI, validation rules, and tests in this repository. |

Runtime commands reject known unsupported surfaces before side effects where the normalized Compose model exposes those fields.

## Status Model

| Status | Docker Compose v2 | Apple `container` | `container-compose` | Current runtime result | Next owner |
| --- | --- | --- | --- | --- | --- |
| Supported | Defines the surface. | Has a usable primitive. | Maps it and has focused tests. | Runs through Apple `container`. | This repository maintains coverage and docs. |
| Apple runtime gap | Defines the surface. | Does not expose enough compatible behavior yet. | Rejects it before side effects. | Fails with an Apple runtime-gap message. | [`apple/container`](https://github.com/apple/container) needs a runtime/API capability first. |
| Plugin implementation gap | Defines the surface. | Appears possible or is not known to be the first blocker. | Does not map it yet. | Fails with a `container-compose` implementation-gap message. | This repository needs design, implementation, and tests. |
| Config-only | Defines the surface. | No runtime primitive is needed for metadata-only output. | Preserves it in `config` or ignores harmless runtime metadata. | `config` shows it; runtime ignores harmless metadata or rejects service-level uses that need a primitive. | This repository keeps normalization and docs accurate. |

## References

- Compose file reference: [docs.docker.com/reference/compose-file](https://docs.docker.com/reference/compose-file/).
- Docker Compose v2 CLI reference: [docs.docker.com/reference/cli/docker/compose](https://docs.docker.com/reference/cli/docker/compose/).
- Docker Compose v2 implementation: [`docker/compose`](https://github.com/docker/compose).
- Docker Compose v2 Go API package: [`github.com/docker/compose/v2/pkg/api`](https://pkg.go.dev/github.com/docker/compose/v2/pkg/api).
- Compose model normalizer used here: [`compose-spec/compose-go`](https://github.com/compose-spec/compose-go).

## At-A-Glance Matrix

This table is the fastest way to see who blocks a Compose v2 surface today.

| Compose v2 surface | Docker Compose v2 | Apple `container` | `container-compose` | Status | Examples |
| --- | --- | --- | --- | --- | --- |
| Project loading and `config` | Supports discovery, multiple files, project names, `.env`, `--env-file`, interpolation, file merge, profiles, extensions, and canonical config output. | Runtime not needed for normalization. | Delegates to `compose-go` and prints canonical JSON. | Supported. | S1, O1 |
| Core local commands | Supports local lifecycle, image, inspection, log, exec, and copy commands. | Exposes primitives for the implemented subset. | Implements `config`, `up`, `down`, `build`, `pull`, `push`, `ps`, `logs`, `exec`, `run`, `start`, `stop`, `restart`, `rm`, `images`, `cp`, `kill`, and `version`. | Supported. | S1 |
| Runtime-data commands | Supports `top`, `events`, `port`, `pause`, `unpause`, and `wait`. | Missing process listing, event stream, richer published-port inspect output, pause/unpause, and wait/exit metadata. | Rejects these commands with Apple runtime-gap messages. | Apple runtime gap. | A4 |
| Extra Compose commands | Supports command surfaces such as `watch`, `stats`, `scale`, `create`, `ls`, `attach`, and `volumes`. | Some may be possible with existing primitives. | Not implemented yet. | Plugin implementation gap. | C1, C4 |
| Builds and images | Supports build definitions, pulls, pushes, pull policies, and build-only services. | Exposes build, image pull, image inspect, and image push primitives for the implemented subset. | Maps `context`, `dockerfile`, `args`, `target`, `no_cache`, service images, generated tags, supported `pull_policy` values, and supported `up --pull` values. | Supported for the listed subset. | S1 |
| Advanced build features | Supports additional contexts, cache import/export, build secrets, SSH, tags, provenance, SBOM, platforms, network, isolation, and entitlements. | Some fields may require build primitive expansion. | Rejects unsupported build fields before any build command. | Plugin implementation gap until proven to be an Apple runtime gap. | C2 |
| Container lifecycle | Supports deterministic service containers and one-off runs. | Exposes run, start, stop, delete, kill, inspect, list, logs, exec, and copy primitives. | Maps names, labels, recreate rules, orphan removal, lifecycle commands, logs, exec, `run`, and service-aware `cp`. | Supported. | S1 |
| Process options | Supports command, entrypoint, working directory, user, TTY, stdin, read-only root, init, platform, runtime, DNS, capabilities, memory, CPU, shared memory, ulimits, stop signal, and stop grace period. | Exposes usable flags for these options. | Maps the listed options to `container run` and stop commands. | Supported. | S1 |
| Advanced runtime controls | Supports namespace, cgroup, advanced CPU, advanced memory/OOM/PID, supplemental group, security option, privileged, device, GPU, credential spec, DNS option, sysctl, MAC, hostname, and domain controls. | Missing compatible controls. | Rejects them before side effects. | Apple runtime gap. | A2, A3 |
| Networking | Supports project networks, external networks, service attachments, ports, aliases, multiple networks, network modes, extra hosts, and legacy links. | Exposes enough for project networks, external networks, one service network, and port publishing; missing multi-network connect, aliases, attachment options, network modes, host entries, hostname/domain, MAC, and legacy links. | Maps the supported subset and rejects the missing runtime subset. | Supported subset plus Apple runtime gaps. | S1, A1, A2 |
| Storage | Supports named, bind, tmpfs, anonymous, external volumes, `configs`, `secrets`, inherited volumes, and API socket mounting. | Exposes usable volume and mount primitives for named/bind/tmpfs/anonymous mounts; missing Compose-style config and secret mounts. | Maps supported volume mounts, rejects `configs` and `secrets` as Apple runtime gaps, and rejects `volumes_from`, service-level `volume_driver`, and `use_api_socket` as plugin gaps. | Supported subset plus Apple and plugin gaps. | S1, A4, C4 |
| Dependencies and health | Supports `depends_on` conditions, healthchecks, and successful-completion gates. | Missing health status plus exit code and completion-time inspection. | Supports dependency order for omitted condition and `service_started`; rejects `service_healthy` and `service_completed_successfully`. | Supported subset plus Apple runtime gaps. | S1, A4 |
| Metadata and extensions | Supports labels, annotations, extension fields, label files, logging, storage options, provider/model surfaces, lifecycle hooks, and develop/watch. | Labels are available; several metadata surfaces do not need runtime support. | Maps Compose/plugin labels, preserves extension fields in `config`, and rejects unmapped service metadata/workflow fields as plugin gaps. | Supported subset, config-only subset, and plugin gaps. | S1, C3, O1 |

## Example Index

Every example includes the relevant `compose.yaml` plus a `Dockerfile` for each build service. The Dockerfiles are intentionally small so the Compose v2 surface, not image complexity, drives the support status.

| Example | Status | Demonstrates | Expected `container-compose` behavior |
| --- | --- | --- | --- |
| S1 | Supported. | Build, pull policy, lifecycle, one network, volumes, ports, process options, labels, dependency order, and teardown. | Commands map to Apple `container` primitives and are covered by focused tests. |
| A1 | Apple runtime gap. | Multiple networks, aliases, fixed IP attachment options, and richer service network configuration. | Runtime commands reject the project before side effects until Apple `container` exposes matching network primitives. |
| A2 | Apple runtime gap. | Hostname, domain name, explicit host entries, MAC address, and legacy links. | Runtime commands reject the project before side effects until Apple `container` exposes compatible host identity and host table controls. |
| A3 | Apple runtime gap. | Namespace, privileged/device, advanced CPU and memory, DNS option, and sysctl controls. | Runtime commands reject the project before side effects until Apple `container` exposes compatible resource and security controls. |
| A4 | Apple runtime gap. | Healthchecks, `service_healthy`, `service_completed_successfully`, secrets, restart policy, and wait-style exit data. | Runtime commands reject the project before side effects until Apple `container` exposes health, completion, secret mount, restart, and wait metadata primitives. |
| C1 | Plugin implementation gap. | Replica scaling. | Apple `container` can create multiple containers, but this plugin still needs Compose replica naming, reconciliation, logs, ps, rm, and discovery semantics. |
| C2 | Plugin implementation gap. | Advanced build fields such as additional contexts, cache wiring, build secrets, and SSH. | The plugin rejects the fields before side effects until they are explicitly mapped to safe build behavior. |
| C3 | Plugin implementation gap. | Develop/watch workflows, metadata surfaces, service providers, service models, and lifecycle hooks. | The plugin rejects the fields before side effects until orchestration and safety rules are designed. |
| C4 | Plugin implementation gap. | Volume inheritance, API socket mounting, block I/O controls, unsupported pull policies, and additional CLI commands. | The plugin rejects the service fields before side effects; the listed extra commands remain unimplemented command work. |
| O1 | Config-only. | `expose`, extension fields, and top-level metadata for secrets and models. | `config` preserves the data, while runtime startup ignores harmless metadata or rejects service-level uses that need runtime behavior. |

## Supported By Both Layers

These Compose v2 surfaces are implemented by `container-compose` and backed by current Apple `container` primitives. Example S1 shows the smallest copyable project that uses this supported set.

| Compose v2 surface | Current behavior | Apple `container` primitive | Example |
| --- | --- | --- | --- |
| Project loading | Compose file discovery, repeated `-f`, project name, project directory, `.env`, `--env-file`, interpolation, merge, and profiles are delegated to `compose-go`. | Normalization helper before runtime orchestration. | S1 |
| `config` | Prints the canonical normalized project JSON. | Local normalizer and Swift JSON encoding. | S1 |
| Image build | Supports `build.context`, `build.dockerfile`, `build.args`, `build.target`, `build.no_cache`, CLI `--no-cache`, explicit service image tags, and generated tags for build-only services. | `container build`. | S1 |
| Image pull | Supports service images, `up --pull always`, `up --pull missing`, `up --pull never`, and service `pull_policy` values `always`, `missing`, `if_not_present`, and `never`. | `container image pull`, `container image inspect`. | S1 |
| Image push | Pushes selected service images. | `container image push`. | S1 |
| Container startup | `up` creates detached service containers by default; `run` creates attached one-off containers. | `container run`. | S1 |
| Container naming | Uses deterministic project-service names, explicit `container_name`, and unique one-off names for `run`. | `container run --name`. | S1 |
| Container lifecycle | `start`, `stop`, `restart`, `rm`, `kill`, and `down` operate on project service containers. | `container start`, `container stop`, `container delete`, `container kill`. | S1 |
| Container inspection | Existing containers are inspected so config hashes can drive reuse/recreate behavior. | `container inspect`. | S1 |
| Container listing | `ps` lists project containers by Compose project labels. | `container list --format json`. | S1 |
| Logs | `logs` supports selected services, follow, and tail options. | `container logs`. | S1 |
| Exec | `exec` runs commands in existing service containers with interactive and TTY flags. | `container exec`. | S1 |
| File copy | `cp` maps `SERVICE:path` operands to deterministic service container names, then delegates the copy to the runtime. | `container cp`. | S1 |
| Networks | Non-external project networks are created/deleted, external names are reused, and each service can attach to one network. | `container network create`, `container network delete`, `container run --network`. | S1 |
| Volumes | Non-external named volumes are created/deleted; external volume names are reused; named, bind, tmpfs, read-only, and stable anonymous mounts are passed through. | `container volume create`, `container volume delete`, `container run --volume`, `container run --tmpfs`. | S1 |
| Environment | Environment variables and service env files are passed through. | `container run --env`, `container run --env-file`. | S1 |
| Ports | Compose port mappings are normalized and published. | `container run --publish`. | S1 |
| Process options | Supports `command`, `entrypoint`, `working_dir`, `user`, `tty`, `stdin_open`, `read_only`, `init`, `platform`, `runtime`, `dns`, `dns_search`, `cap_add`, `cap_drop`, `mem_limit`, `cpus`, `shm_size`, and `ulimits`. | `container run` flags. | S1 |
| Labels | Applies Compose project, service, one-off state, working directory, compose-file hash, config hash, and resource labels. | `container run --label`, `container network create --label`, `container volume create --label`. | S1 |
| Dependency order | Honors `depends_on` when the condition is omitted or `service_started`. | Orchestrator ordering before `container run`. | S1 |
| Reconciliation | Reuses, recreates, or removes containers based on config hash, `--force-recreate`, `--no-recreate`, and `--remove-orphans`. | `container inspect`, `container stop`, `container delete`, `container list`. | S1 |
| Stop behavior | Applies service `stop_signal` and `stop_grace_period` to stop, restart, rm-with-stop, recreate, and down flows. | `container stop --signal`, `container stop --time`. | S1 |
| Project teardown | `down` stops/deletes project containers, deletes non-external networks, and deletes volumes only with `--volumes`. | `container stop`, `container delete`, `container network delete`, `container volume delete`. | S1 |
| Version | Prints the plugin version. | Local command. | S1 |

## Compose v2 Supported, Blocked By Apple `container`

These Compose v2 surfaces are valid Docker Compose features, but `container-compose` cannot preserve their semantics until Apple `container` exposes matching runtime/API primitives.

| Compose v2 surface | Example fields or commands | Missing Apple `container` behavior | Example |
| --- | --- | --- | --- |
| Multiple service networks | Two or more service `networks` entries. | Post-create network connect and multi-network attachment. | A1 |
| Service network aliases and attachment options | `aliases`, `driver_opts`, `gw_priority`, `interface_name`, `ipv4_address`, `ipv6_address`, `link_local_ips`, service-level network `mac_address`, `priority`. | Network aliases and rich network attachment configuration. | A1 |
| Network namespace modes | `network_mode: host`, `network_mode: none`, `network_mode: service:api`, `network_mode: container:name`. | Docker-compatible network namespace modes. | A1 |
| Host identity and host table controls | `hostname`, `domainname`, `extra_hosts`, service `mac_address`. | Compose-compatible hostname/domain, explicit host entries, and MAC address controls. | A2 |
| Legacy links | `links`, `external_links`. | Legacy alias/link behavior and host-entry semantics. | A2 |
| Namespace and isolation controls | `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, `isolation`. | Namespace selection and parent cgroup controls. | A3 |
| Advanced CPU controls | `cpu_count`, `cpu_percent`, `cpu_period`, `cpu_quota`, `cpu_rt_period`, `cpu_rt_runtime`, `cpuset`, `cpu_shares`. | CPU scheduler controls beyond supported `cpus`. | A3 |
| Advanced memory, OOM, and PID controls | `mem_reservation`, `memswap_limit`, `mem_swappiness`, `oom_kill_disable`, `oom_score_adj`, `pids_limit`. | Resource controls beyond supported `mem_limit`. | A3 |
| User, security, and device access | `group_add`, `security_opt`, `privileged`, `credential_spec`, `device_cgroup_rules`, `devices`, `gpus`. | Supplemental groups, security options, privileged mode, Windows credential specs, host devices, cgroup device rules, and GPU device requests. | A3 |
| DNS and kernel tuning | `dns_opt`, `sysctls`. | Compose-compatible DNS resolver options and per-container sysctl behavior. | A3 |
| Health and completion conditions | `healthcheck`, `depends_on.condition: service_healthy`, `depends_on.condition: service_completed_successfully`. | Health status, exit code, and completion-time inspection. | A4 |
| Config and secret mounts | Service-level `configs` and `secrets`. | Compose-style config/secret mount primitives. | A4 |
| Runtime restart policy | Service `restart`. | Docker-compatible automatic restart policies. | A4 |
| Runtime CLI data | `top`, `events`, `port`, `pause`, `unpause`, `wait`. | Process listing, event stream, richer published-port inspect output, pause/unpause, and wait/exit metadata. | A4 |

## Compose v2 Supported, Blocked By `container-compose`

These Compose v2 surfaces are not supported by `stephenlclarke/container-compose` yet. The first known blocker is plugin work, not an Apple runtime limitation.

| Compose v2 surface | Current behavior | Why this is a plugin gap | Example |
| --- | --- | --- | --- |
| Service replica scaling | Explicit `scale` and `deploy.replicas` values other than `1` fail before side effects. | The plugin currently manages one deterministic container per service. Multi-replica naming, reconciliation, logs, ps, rm, and DNS behavior are not implemented. | C1 |
| Advanced build fields | Unsupported build fields fail before any `container build` command is emitted. | Only `context`, `dockerfile`, `args`, `target`, and `no_cache` are mapped. Additional contexts, cache exporters/importers, build labels, platforms, secrets, SSH, tags, provenance, SBOM, build network/isolation/entitlements, and similar fields need mapping work. | C2 |
| Compose Deploy Specification beyond local replica count | Unsupported `deploy` fields fail before side effects. | Swarm-style mode, placement, update, rollback, endpoint, labels, restart policy, and resource limits/reservations are outside the current local workflow mapping. | C1, C3 |
| Develop/watch workflow | `develop` and watch settings fail before side effects. | File watching, sync, rebuild actions, and debounce/reconcile semantics need plugin orchestration. | C3 |
| Provider, model, and lifecycle hook surfaces | Service `provider`, service `models`, `post_start`, and `pre_stop` fail before side effects. | These need orchestration design and safety rules before they can affect managed containers. | C3 |
| Service metadata and logging surfaces | `annotations`, `attach`, `label_file`, `logging`, and `storage_opt` fail before side effects when Compose v2 accepts them. | The plugin has not mapped them to runtime behavior. Legacy `log_driver` and `log_opt` are rejected by the Compose v2 schema during normalization, with defensive validation if they appear in canonical JSON. | C3 |
| Volume inheritance and driver shortcuts | `volumes_from` fails before side effects when Compose v2 accepts it. | The plugin has not implemented inherited mount behavior. Legacy service-level `volume_driver` is rejected by the Compose v2 schema during normalization, with defensive validation if it appears in canonical JSON. | C4 |
| API socket mounting | `use_api_socket` fails before side effects. | The feature needs a security review and explicit mount policy. | C4 |
| Block I/O controls | `blkio_config` fails before side effects. | Block I/O weights and throttle-device limits need runtime mapping work. | C4 |
| Unsupported service pull policies | Unsupported values fail before side effects. | The plugin supports only `always`, `missing`, `if_not_present`, and `never`; values such as `build`, `daily`, `weekly`, and duration windows need separate semantics. | C4 |
| Additional Docker Compose CLI commands and flags | Commands not listed in the supported table are not implemented. | `create`, `ls`, `watch`, `stats`, `scale`, `attach`, `commit`, `convert`, `export`, `publish`, `volumes`, and advanced flags on supported commands need separate command work. | C4 |

## Compose v2 Config-Only Surfaces

These Compose v2 surfaces are normalized and preserved because they are useful in `container compose config` output or harmless as metadata, but they do not currently change runtime orchestration.

| Compose v2 surface | Current behavior | Example |
| --- | --- | --- |
| Service `expose` | Preserved in normalized config; no runtime host publishing is performed. Use `ports` for host publishing. | O1 |
| Extension fields | Project and service `x-*` fields are preserved in normalized config. | O1 |
| Top-level `configs` and `secrets` definitions | Preserved in normalized config. Service-level use is rejected because mounting them needs runtime support. | O1 |
| Top-level `models` definitions | Preserved in normalized config. Service-level model bindings are rejected because runtime model wiring is not implemented. | O1 |

## Dockerfile-Backed Examples

Each example includes a `compose.yaml` and a matching `Dockerfile` for each build service. The Dockerfiles are intentionally small so the support status is driven by the Compose surface, not by image complexity.

### S1: Supported Today

This project uses supported local-development surfaces: build, `build.no_cache`, image pull policy, ports, environment, one network, one named volume, CPU/memory limits, stop behavior, and simple `service_started` dependency ordering.

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
      redis:
        condition: service_started
    cpus: "1.5"
    mem_limit: 256m
    stop_signal: SIGTERM
    stop_grace_period: 10s

  redis:
    image: redis:7
    networks:
      - app

networks:
  app: {}

volumes:
  api-cache: {}
```

```dockerfile
# api/Dockerfile
FROM alpine:3.20
ARG APP_ENV=dev
RUN mkdir -p /app /cache && printf '%s\n' "$APP_ENV" > /app/env.txt
EXPOSE 8080
CMD ["sh", "-c", "sleep 3600"]
```

### A1: Apple `container` Gap, Multi-Network Attachment

This project is valid Docker Compose v2, but it needs multiple network attachments plus service aliases and fixed attachment options. `container-compose up` rejects it before creating resources because Apple `container` does not expose the needed Compose-compatible network behavior.

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

networks:
  app: {}
  admin:
    ipam:
      config:
        - subnet: 10.10.0.0/24
```

```dockerfile
# api/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

### A2: Apple `container` Gap, Host Identity And Legacy Links

This project is valid Docker Compose v2, but hostname/domain, explicit host entries, MAC address, and legacy link semantics need runtime support that is not exposed yet.

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

```dockerfile
# api/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

```dockerfile
# db/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

### A3: Apple `container` Gap, Namespace, Device, And Advanced Resource Controls

This project is valid Docker Compose v2, but it needs namespace selection, privileged/device access, advanced CPU/memory controls, DNS resolver options, and sysctls that Apple `container` does not currently expose with Compose-compatible semantics.

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

```dockerfile
# api/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

### A4: Apple `container` Gap, Health, Completion, Secrets, Restart, And Runtime Data

This project is valid Docker Compose v2, but the health gate, successful-completion dependency, secret mount, restart policy, and `compose wait`-style exit data need Apple runtime primitives first.

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

```dockerfile
# migrate/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "touch /tmp/done"]
```

```dockerfile
# api/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "touch /tmp/ready && sleep 3600"]
```

```dockerfile
# worker/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "echo worker-ready && sleep 3600"]
```

### C1: `container-compose` Gap, Replica Scaling

This project is valid Docker Compose v2, and Apple `container` can create multiple containers in general, but this plugin does not yet implement Docker Compose replica naming, lifecycle, log, ps, rm, or DNS semantics. It fails before side effects.

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

```dockerfile
# worker/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

### C2: `container-compose` Gap, Advanced Build Fields

This project is valid Docker Compose v2, but build cache wiring, additional contexts, and build secret handling are plugin work. It fails before any `container build` command is emitted.

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

```dockerfile
# api/Dockerfile
FROM alpine:3.20
RUN mkdir -p /app
CMD ["sh", "-c", "sleep 3600"]
```

### C3: `container-compose` Gap, Develop, Metadata, Provider, Models, And Hooks

This project is valid Docker Compose v2, but file watching, service providers, service-level model bindings, lifecycle hooks, annotations, label files, and logging options need plugin orchestration and safety rules before they can run.

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

```dockerfile
# api/Dockerfile
FROM alpine:3.20
WORKDIR /app
CMD ["sh", "-c", "sleep 3600"]
```

### C4: `container-compose` Gap, Volume Shortcuts, API Socket, Block I/O, Pull Policy, And Extra CLI Work

This project is valid Docker Compose v2, but inherited mounts, API socket exposure, block I/O controls, and time-window pull policies need plugin implementation and security review. Separately, commands such as `compose stats`, `compose scale`, and `compose watch` still need command-level work.

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

```dockerfile
# base/Dockerfile
FROM alpine:3.20
RUN mkdir -p /data
CMD ["sh", "-c", "sleep 3600"]
```

```dockerfile
# worker/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

### O1: Config-Only

This project keeps extension metadata, top-level model metadata, top-level secret metadata, and `expose` in config output. Runtime startup ignores that metadata and does not publish `expose` to the host.

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

```dockerfile
# api/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

## Maintenance Rule

When a change adds, removes, or changes a Compose-to-`container` runtime mapping, update this file in the same commit or pull request. Do not mark a primitive as supported until the orchestrator maps it, rejects unsupported alternatives clearly, and has focused test coverage.
