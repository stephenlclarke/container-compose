# Compatibility

`container-compose` targets local-development Docker Compose v2 workflows where Apple's [`container`](https://github.com/apple/container) CLI exposes matching runtime primitives.

This file answers one practical question: when a Compose v2 project does not run under `container compose`, who owns the missing behavior?

## Status Buckets

| Bucket | What Docker Compose v2 says | What [`apple/container`](https://github.com/apple/container) provides | What [`stephenlclarke/container-compose`](https://github.com/stephenlclarke/container-compose) does | Runtime result |
| --- | --- | --- | --- | --- |
| Supported by both layers | The surface is valid Compose v2. | A compatible runtime primitive exists. | The plugin maps the surface and has focused coverage. | Runs through Apple `container`. |
| Blocked by Apple `container` | The surface is valid Compose v2. | A compatible primitive is missing or not rich enough. | The plugin rejects the surface before side effects. | Fails with an Apple runtime-gap message. |
| Blocked by `container-compose` | The surface is valid Compose v2. | Apple `container` is not known to be the first blocker. | The plugin has not mapped the surface yet. | Fails with a plugin implementation-gap message. |
| Config-only | The surface is valid Compose v2 metadata or model data. | No runtime primitive is needed unless a service consumes it. | `config` preserves it; runtime ignores harmless metadata or rejects service-level use that needs behavior. | Visible in `config`; no runtime side effect. |

The tables below use those same buckets. "Blocked by Apple `container`" means this repository should not fake the behavior; an upstream [`apple/container`](https://github.com/apple/container) runtime/API capability is needed first. "Blocked by `container-compose`" means this repository needs plugin design, implementation, and tests.

## References

- Compose file reference: [docs.docker.com/reference/compose-file](https://docs.docker.com/reference/compose-file/).
- Docker Compose v2 CLI reference: [docs.docker.com/reference/cli/docker/compose](https://docs.docker.com/reference/cli/docker/compose/).
- Docker Compose v2 implementation: [`docker/compose`](https://github.com/docker/compose).
- Docker Compose v2 Go API package: [`github.com/docker/compose/v2/pkg/api`](https://pkg.go.dev/github.com/docker/compose/v2/pkg/api).
- Compose model normalizer used here: [`compose-spec/compose-go`](https://github.com/compose-spec/compose-go).

## Supported By Both Layers

These surfaces are valid Docker Compose v2, have matching Apple `container` primitives, and are mapped by `container-compose`.

| Compose v2 surface | `container-compose` support | Apple `container` primitive | Example |
| --- | --- | --- | --- |
| Project loading and `config` | File discovery, repeated `-f`, `--project-name`, `--project-directory`, `.env`, `--env-file`, interpolation, file merge, profiles, extensions, and canonical JSON output are delegated to `compose-go`. | No runtime primitive required for normalization. | S1, O1 |
| Build subset | `build.context`, `build.dockerfile`, `build.args`, `build.target`, `build.no_cache`, CLI `--no-cache`, explicit image tags, and generated tags for build-only services. | `container build`. | S1 |
| Image operations | Pull, push, image lookup, `up --pull always`, `up --pull missing`, `up --pull never`, and service `pull_policy` values `always`, `missing`, `if_not_present`, and `never`. | `container image pull`, `container image inspect`, `container image push`. | S1 |
| Container lifecycle | `up`, `down`, `run`, `start`, `stop`, `restart`, `rm`, `kill`, deterministic service names, explicit `container_name`, one-off names, config-hash reuse/recreate, and orphan removal. | `container run`, `container start`, `container stop`, `container delete`, `container kill`, `container inspect`, `container list`. | S1 |
| Inspection and interaction | `ps`, `logs`, `exec`, `images`, and service-aware `cp`. | `container list`, `container logs`, `container exec`, `container image list`, `container cp`. | S1 |
| Basic networking | Project networks, external networks, one network attachment per service, and published ports. | `container network create`, `container network delete`, `container run --network`, `container run --publish`. | S1 |
| Basic storage | Named volumes, bind mounts, tmpfs mounts, anonymous volumes, external volumes, read-only mounts, and `down --volumes`. | `container volume create`, `container volume delete`, `container run --volume`, `container run --tmpfs`. | S1 |
| Runtime process options | `command`, `entrypoint`, `working_dir`, `user`, `tty`, `stdin_open`, `read_only`, `init`, `platform`, `runtime`, `dns`, `dns_search`, `cap_add`, `cap_drop`, `mem_limit`, `cpus`, `shm_size`, `ulimits`, `stop_signal`, and `stop_grace_period`. | `container run` and `container stop` flags. | S1 |
| Environment and labels | Service environment, service env files, Compose project labels, service labels, one-off labels, config hash labels, working-directory labels, and compose-file hash labels. | `container run --env`, `container run --env-file`, `container run --label`, resource label flags. | S1 |
| Simple dependencies | `depends_on` with no condition or `condition: service_started`. | Orchestrator ordering before `container run`. | S1 |
| Version | `container compose version`. | Local plugin command. | S1 |

## Blocked By Apple `container`

These surfaces are valid Docker Compose v2 and are recognized by `container-compose`, but the plugin rejects them because Apple `container` does not currently expose a compatible primitive in the runtime baseline tracked by this repository.

| Compose v2 surface | Example fields or commands | Missing Apple `container` behavior | Example |
| --- | --- | --- | --- |
| Multi-network attachment | Two or more service `networks` entries. | Post-create network connect and multi-network attachment. | A1 |
| Network aliases and attachment options | `aliases`, `driver_opts`, `gw_priority`, `interface_name`, `ipv4_address`, `ipv6_address`, `link_local_ips`, service-level network `mac_address`, and `priority`. | Compose-compatible network aliases and rich attachment configuration. | A1 |
| Network namespace modes | `network_mode: host`, `network_mode: none`, `network_mode: service:api`, and `network_mode: container:name`. | Docker-compatible network namespace modes. | A1 |
| Host identity and host table controls | `hostname`, `domainname`, `extra_hosts`, and service `mac_address`. | Compose-compatible hostname/domain, explicit host entries, and MAC address controls. | A2 |
| Legacy links | `links` and `external_links`. | Legacy alias/link behavior and host-entry semantics. | A2 |
| Namespace and isolation controls | `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, and `isolation`. | Namespace selection and parent cgroup controls. | A3 |
| Advanced CPU controls | `cpu_count`, `cpu_percent`, `cpu_period`, `cpu_quota`, `cpu_rt_period`, `cpu_rt_runtime`, `cpuset`, and `cpu_shares`. | CPU scheduler controls beyond supported `cpus`. | A3 |
| Advanced memory, OOM, and PID controls | `mem_reservation`, `memswap_limit`, `mem_swappiness`, `oom_kill_disable`, `oom_score_adj`, and `pids_limit`. | Resource controls beyond supported `mem_limit`. | A3 |
| User, security, and device access | `group_add`, `security_opt`, `privileged`, `credential_spec`, `device_cgroup_rules`, `devices`, and `gpus`. | Supplemental groups, security options, privileged mode, Windows credential specs, host devices, cgroup device rules, and GPU device requests. | A3 |
| DNS and kernel tuning | `dns_opt` and `sysctls`. | Compose-compatible DNS resolver options and per-container sysctl behavior. | A3 |
| Health and completion conditions | `healthcheck`, `depends_on.condition: service_healthy`, and `depends_on.condition: service_completed_successfully`. | Health status, exit code, and completion-time inspection. | A4 |
| Config and secret mounts | Service-level `configs` and `secrets`. | Compose-style config and secret mount primitives. | A4 |
| Runtime restart policy | Service `restart`. | Docker-compatible automatic restart policies. | A4 |
| Runtime data commands | `top`, `events`, `port`, `pause`, `unpause`, and `wait`. | Process listing, event stream, richer published-port inspect output, pause/unpause, and wait/exit metadata. | A4 |

## Blocked By `container-compose`

These surfaces are valid Docker Compose v2, but the missing work is in this repository. They should stay rejected until the plugin has explicit design, implementation, and tests.

| Compose v2 surface | Current behavior | Why this is a plugin gap | Example |
| --- | --- | --- | --- |
| Service replica scaling | Explicit `scale` and `deploy.replicas` values other than `1` fail before side effects. | The plugin currently manages one deterministic container per service. Multi-replica naming, reconciliation, logs, `ps`, `rm`, and DNS behavior are not implemented. | C1 |
| Advanced build fields | Unsupported build fields fail before any `container build` command is emitted. | Only `context`, `dockerfile`, `args`, `target`, and `no_cache` are mapped. Additional contexts, cache exporters/importers, build labels, platforms, secrets, SSH, tags, provenance, SBOM, build network/isolation/entitlements, and similar fields need mapping work. | C2 |
| Compose Deploy Specification beyond local replica count | Unsupported `deploy` fields fail before side effects. | Swarm-style mode, placement, update, rollback, endpoint, labels, restart policy, and resource limits/reservations are outside the current local workflow mapping. | C1 |
| Develop/watch workflow | `develop` and watch settings fail before side effects. | File watching, sync, rebuild actions, and debounce/reconcile semantics need plugin orchestration. | C3 |
| Provider, model, and lifecycle hook surfaces | Service `provider`, service `models`, `post_start`, and `pre_stop` fail before side effects. | These need orchestration design and safety rules before they can affect managed containers. | C3 |
| Service metadata and logging surfaces | `annotations`, `attach`, `label_file`, `logging`, and `storage_opt` fail before side effects when Compose v2 accepts them. | The plugin has not mapped them to runtime behavior. Legacy `log_driver` and `log_opt` are rejected by the Compose v2 schema during normalization, with defensive validation if they appear in canonical JSON. | C3 |
| Volume inheritance and driver shortcuts | `volumes_from` fails before side effects when Compose v2 accepts it. | The plugin has not implemented inherited mount behavior. Legacy service-level `volume_driver` is rejected by the Compose v2 schema during normalization, with defensive validation if it appears in canonical JSON. | C4 |
| API socket mounting | `use_api_socket` fails before side effects. | The feature needs a security review and explicit mount policy. | C4 |
| Block I/O controls | `blkio_config` fails before side effects. | Block I/O weights and throttle-device limits need runtime mapping work. | C4 |
| Unsupported service pull policies | Unsupported values fail before side effects. | The plugin supports only `always`, `missing`, `if_not_present`, and `never`; values such as `build`, `daily`, `weekly`, and duration windows need separate semantics. | C4 |
| Additional Docker Compose CLI commands and flags | Commands not listed in the supported table are not implemented. | `create`, `ls`, `watch`, `stats`, `scale`, `attach`, `commit`, `convert`, `export`, `publish`, `volumes`, and advanced flags on supported commands need separate command work. | C4 |

## Config-Only Surfaces

These surfaces are normalized and preserved because they are useful in `container compose config` output or harmless as metadata, but they do not currently change runtime orchestration.

| Compose v2 surface | Current behavior | Example |
| --- | --- | --- |
| Service `expose` | Preserved in normalized config; no runtime host publishing is performed. Use `ports` for host publishing. | O1 |
| Extension fields | Project and service `x-*` fields are preserved in normalized config. | O1 |
| Top-level `configs` and `secrets` definitions | Preserved in normalized config. Service-level use is rejected because mounting them needs runtime support. | O1 |
| Top-level `models` definitions | Preserved in normalized config. Service-level model bindings are rejected because runtime model wiring is not implemented. | O1 |

## Example Index

Every example includes the relevant `compose.yaml` and a matching `Dockerfile` for every service that declares `build:`. The Dockerfiles are intentionally small so the Compose surface, not image complexity, drives the support status.

| Example | Bucket | Demonstrates | Expected behavior |
| --- | --- | --- | --- |
| S1 | Supported by both layers. | Build, image tag, lifecycle, one network, volumes, ports, process options, labels, dependency order, and teardown. | Runs through Apple `container`. |
| A1 | Blocked by Apple `container`. | Multiple networks, aliases, fixed IP attachment options, and network mode. | Rejected before side effects with an Apple runtime-gap message. |
| A2 | Blocked by Apple `container`. | Hostname, domain name, explicit host entries, MAC address, and legacy links. | Rejected before side effects with an Apple runtime-gap message. |
| A3 | Blocked by Apple `container`. | Namespace, privileged/device, advanced CPU and memory, DNS option, and sysctl controls. | Rejected before side effects with an Apple runtime-gap message. |
| A4 | Blocked by Apple `container`. | Healthchecks, `service_healthy`, `service_completed_successfully`, secrets, restart policy, and wait-style exit data. | Rejected before side effects with an Apple runtime-gap message. |
| C1 | Blocked by `container-compose`. | Replica scaling. | Rejected before side effects with a plugin implementation-gap message. |
| C2 | Blocked by `container-compose`. | Advanced build fields. | Rejected before side effects with a plugin implementation-gap message. |
| C3 | Blocked by `container-compose`. | Develop/watch, metadata, provider, models, and hooks. | Rejected before side effects with a plugin implementation-gap message. |
| C4 | Blocked by `container-compose`. | Volume shortcuts, API socket, block I/O, pull policy, and extra CLI work. | Rejected before side effects with a plugin implementation-gap message. |
| O1 | Config-only. | `expose`, extension fields, and top-level metadata for secrets and models. | `config` preserves the data; runtime ignores harmless metadata or rejects service-level uses that need runtime behavior. |

## Examples

### S1: Supported Local Web Stack

This project uses only surfaces supported by both `container-compose` and Apple `container`: build, image tagging, ports, environment, one network, one named volume, CPU/memory limits, stop behavior, and simple `service_started` dependency ordering.

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

### A1: Apple Gap - Multiple Networks And Aliases

This project is valid Docker Compose v2, but it needs multiple network attachments plus aliases, fixed IP attachment options, and network namespace modes. `container-compose up` rejects it before creating resources because Apple `container` does not expose compatible network behavior yet.

```yaml
# compose.yaml
name: apple-network-gap-demo

services:
  api:
    build:
      context: ./api
    network_mode: service:gateway
    networks:
      app:
        aliases:
          - api.internal
      admin:
        ipv4_address: 10.10.0.20

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

Dockerfile: `gateway/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

### A2: Apple Gap - Host Identity And Legacy Links

This project is valid Docker Compose v2, but hostname/domain, explicit host entries, MAC address, and legacy link semantics need runtime support that Apple `container` does not expose yet.

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

### A3: Apple Gap - Runtime Controls

This project is valid Docker Compose v2, but namespace selection, privileged/device access, advanced CPU/memory controls, DNS resolver options, and sysctls require Apple `container` runtime primitives that are not available yet.

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

### A4: Apple Gap - Health, Secrets, Restart, And Runtime Data

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

### C1: Plugin Gap - Replica Scaling

This project is valid Docker Compose v2, and Apple `container` can create multiple containers in general, but `container-compose` does not yet implement Compose replica naming, lifecycle, logs, `ps`, `rm`, or DNS semantics.

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

### C2: Plugin Gap - Advanced Build Fields

This project is valid Docker Compose v2, but build cache wiring, additional contexts, build secrets, and SSH forwarding need explicit plugin mapping before any `container build` command can safely run.

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

### C3: Plugin Gap - Develop, Metadata, Provider, Models, And Hooks

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

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
WORKDIR /app
CMD ["sh", "-c", "sleep 3600"]
```

### C4: Plugin Gap - Miscellaneous Local Workflow Work

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

### O1: Config-Only Metadata

This project keeps extension metadata, top-level model metadata, top-level secret metadata, and `expose` in config output. Runtime startup ignores harmless metadata and does not publish `expose` to the host.

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

When a change adds, removes, or changes a Compose-to-`container` runtime mapping, update this file in the same commit or pull request. Do not mark a primitive as supported until the orchestrator maps it, rejects unsupported alternatives clearly, and has focused test coverage.
