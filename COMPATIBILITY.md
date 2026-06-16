# Compatibility

`container-compose` targets local-development Docker Compose v2 workflows where
Apple's [`container`](https://github.com/apple/container) CLI exposes matching
runtime primitives.

This file answers three separate questions:

1. Which Compose v2 surfaces work through
   [`stephenlclarke/container-compose`](https://github.com/stephenlclarke/container-compose)
   today?
2. Which Compose v2 surfaces are blocked because Apple
   [`container`](https://github.com/apple/container) does not expose the needed
   runtime primitive yet?
3. Which Compose v2 surfaces could plausibly be implemented on top of today's
   Apple `container` CLI, but are not implemented by `container-compose` yet?

## References

- Compose file reference:
  [docs.docker.com/reference/compose-file](https://docs.docker.com/reference/compose-file/).
- Docker Compose v2 CLI reference:
  [docs.docker.com/reference/cli/docker/compose](https://docs.docker.com/reference/cli/docker/compose/).
- Docker Compose v2 implementation:
  [`docker/compose`](https://github.com/docker/compose).
- Docker Compose v2 Go API package:
  [`github.com/docker/compose/v2/pkg/api`](https://pkg.go.dev/github.com/docker/compose/v2/pkg/api).
- Compose model normalizer used here:
  [`compose-spec/compose-go`](https://github.com/compose-spec/compose-go).

## Status Legend

| Status | Owner | Runtime behavior |
| --- | --- | --- |
| Supported | `container-compose` | The plugin maps the Compose surface to an Apple `container` primitive and has focused tests for that mapping. |
| Apple `container` gap | Apple `container` runtime/API | The Compose surface is valid, but the Apple runtime does not expose enough behavior to match Docker Compose semantics. Runtime commands fail before side effects where validation exists. |
| `container-compose` gap | This plugin | Apple `container` can likely provide enough low-level behavior, but the plugin orchestration, validation, or security design is not implemented yet. Runtime commands fail before side effects where validation exists. |
| Config-only | This plugin | The surface is preserved for `container compose config` output or harmless metadata, but does not affect runtime orchestration. |

## Quick Matrix

| Area | Supported today | Apple `container` gaps | `container-compose` gaps |
| --- | --- | --- | --- |
| Project loading and config | Compose file discovery, repeated `-f`, `-p`, project directory, `.env`, `--env-file`, interpolation, merge, profiles, and canonical `config` output through `compose-go`. | None known for local normalization. | Advanced project model surfaces not emitted in the normalized model yet. |
| Core lifecycle CLI | `config`, `up`, `down`, `build`, `pull`, `push`, `ps`, `logs`, `exec`, `run`, `start`, `stop`, `restart`, `rm`, `images`, `cp`, `kill`, and `version`. | `top`, `events`, `port`, `pause`, `unpause`, and `wait` need runtime data or commands Apple `container` does not expose yet. | Additional Docker Compose commands such as `attach`, `commit`, `create`, `convert`, `export`, `ls`, `publish`, `scale`, `stats`, `volumes`, `watch`, and alpha/bridge commands. |
| Build and images | `build.context`, `build.dockerfile`, `build.args`, `build.target`, `--no-cache`, generated build-only tags, service images, `pull`, `push`, service `pull_policy` values `always`, `missing`, `if_not_present`, and `never`, plus `up --pull` values `always`, `missing`, and `never`. | None known for the implemented build subset. | Additional build contexts, cache import/export, build labels, build platforms, build secrets, SSH forwarding, extra build tags, provenance/SBOM, and unsupported pull policies such as `build`, `daily`, and `weekly`. |
| Containers and process options | Deterministic names, explicit `container_name`, `command`, `entrypoint`, `working_dir`, `user`, `tty`, `stdin_open`, `read_only`, `init`, `platform`, `runtime`, `dns`, `dns_search`, `cap_add`, `cap_drop`, `mem_limit`, `cpus`, `shm_size`, `ulimits`, `stop_signal`, and `stop_grace_period`. | Namespace, isolation, cgroup, advanced CPU, advanced memory/OOM/PID, supplemental group/security options, privileged mode, devices, GPU, credential spec, restart policy, `dns_opt`, and `sysctls`. | `blkio_config`, `use_api_socket`, service metadata/logging/storage settings, service lifecycle hooks, service providers, service model bindings, and `develop`/watch workflows. |
| Networking | Project networks, external networks, one service network attachment, port publishing, `dns`, and `dns_search`. | Multiple service networks, post-create network connect, service aliases, service network attachment options, `network_mode`, `extra_hosts`, `hostname`, `domainname`, MAC address controls, `links`, and `external_links`. | Rich service discovery behavior beyond a single runtime network attachment. |
| Storage | Project volumes, external volumes, named volumes, bind mounts, tmpfs mounts, read-only mounts, stable anonymous volume names, and `down --volumes`. | Service-level `configs` and `secrets` mounts need runtime primitives. | `volumes_from`, legacy service-level `volume_driver`, advanced volume driver semantics, and API socket mounting. |
| Dependencies and health | `depends_on` with omitted condition or `service_started`. | `healthcheck`, `service_healthy`, and `service_completed_successfully` need health status, exit code, and completion-time inspection. | Higher-level wait orchestration after the runtime data exists. |
| Metadata | Compose labels plus plugin labels for project, service, one-off state, working directory, compose-file hash, config hash, networks, and volumes. | None known for labels already mapped. | `annotations`, `attach`, `label_file`, `logging`, `storage_opt`, and deploy metadata. |

## Supported Today

These Compose v2 surfaces are implemented by `container-compose` and backed by
current Apple `container` primitives.

| Compose v2 surface | Supported behavior | Apple `container` primitive |
| --- | --- | --- |
| Project loading | Compose file discovery, repeated `-f`, project name, project directory, `.env`, `--env-file`, interpolation, merge, and profiles are delegated to `compose-go`. | Normalization helper before runtime orchestration |
| `config` | Prints the canonical normalized project JSON. | Local normalizer and Swift JSON encoding |
| Image build | `build.context`, `build.dockerfile`, `build.args`, `build.target`, `--no-cache`, explicit service image tags, and generated tags for build-only services. | `container build` |
| Image pull | Service images, `up --pull always`, `up --pull missing`, `up --pull never`, and service `pull_policy` values `always`, `missing`, `if_not_present`, and `never`. | `container image pull`, `container image inspect` |
| Image push | Pushes selected service images. | `container image push` |
| Container startup | `up` creates detached service containers by default; `run` creates attached one-off containers. | `container run` |
| Container naming | Deterministic project-service names, explicit `container_name` for managed service containers, and unique one-off names for `run`. | `container run --name` |
| Container lifecycle | `start`, `stop`, `restart`, `rm`, `kill`, and `down` for project service containers. | `container start`, `container stop`, `container delete`, `container kill` |
| Container inspection | Existing containers are inspected to compare config hashes before reuse or recreate. | `container inspect` |
| Container listing | `ps` lists project containers and filters by Compose project labels. | `container list --format json` |
| Logs | `logs` supports selected services, follow, and tail options. | `container logs` |
| Exec | `exec` runs commands in existing service containers with interactive and TTY flags. | `container exec` |
| File copy | `cp` delegates copy arguments to the underlying runtime. | `container cp` |
| Networks | Non-external project networks are created/deleted, external names are reused, and a service can attach to one network. | `container network create`, `container network delete`, `container run --network` |
| Volumes | Non-external named volumes are created/deleted, external volume names are reused, and named, bind, tmpfs, read-only, and stable anonymous volume arguments are mounted. | `container volume create`, `container volume delete`, `container run --volume`, `container run --tmpfs` |
| Environment | Environment variables and service env files are passed through. | `container run --env`, `container run --env-file` |
| Ports | Compose port mappings are normalized and published. | `container run --publish` |
| Process options | `command`, `entrypoint`, `working_dir`, `user`, `tty`, `stdin_open`, `read_only`, `init`, `platform`, `runtime`, `dns`, `dns_search`, `cap_add`, `cap_drop`, `mem_limit`, `cpus`, `shm_size`, and `ulimits`. | `container run` flags |
| Labels | Compose project, service, one-off state, working directory, compose-file hash, config hash, and resource labels are applied. | `container run --label`, `container network create --label`, `container volume create --label` |
| Dependency order | `depends_on` is honored when the condition is omitted or `service_started`. | Orchestrator ordering before `container run` |
| Reconciliation | Containers are reused, recreated, or removed based on config hash, `--force-recreate`, `--no-recreate`, and `--remove-orphans`. | `container inspect`, `container stop`, `container delete`, `container list` |
| Stop behavior | Service `stop_signal` and `stop_grace_period` apply to stop, restart, rm with stop, recreate, and down flows. | `container stop --signal`, `container stop --time` |
| Project teardown | `down` stops/deletes project containers, deletes non-external networks, and deletes volumes only with `--volumes`. | `container stop`, `container delete`, `container network delete`, `container volume delete` |
| Version | Prints the plugin version. | Local command |

## Blocked By Apple `container`

These are valid Docker Compose v2 surfaces that need Apple `container`
runtime/API support before this plugin can implement them faithfully.

| Compose v2 surface | Example fields | Missing Apple `container` primitive |
| --- | --- | --- |
| Multiple service networks | Two or more entries under service `networks`. | Post-create network connect and multi-network attachment. |
| Service network aliases and attachment options | `aliases`, `driver_opts`, `gw_priority`, `interface_name`, `ipv4_address`, `ipv6_address`, `link_local_ips`, service-level network `mac_address`, `priority`. | Network aliasing and rich network attachment configuration. |
| Network namespace modes | `network_mode: host`, `network_mode: none`, `network_mode: service:api`, `network_mode: container:name`. | Docker-compatible network namespace modes. |
| Hostname and host table controls | `hostname`, `domainname`, `extra_hosts`, service `mac_address`. | Explicit host entries, custom hostname/domain name, and MAC address support. |
| Namespace and isolation controls | `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, `isolation`. | Namespace selection and parent cgroup controls. |
| Advanced CPU controls | `cpu_count`, `cpu_percent`, `cpu_period`, `cpu_quota`, `cpu_rt_period`, `cpu_rt_runtime`, `cpuset`, `cpu_shares`. | CPU scheduler controls beyond supported `cpus`. |
| Advanced memory, OOM, and PID controls | `mem_reservation`, `memswap_limit`, `mem_swappiness`, `oom_kill_disable`, `oom_score_adj`, `pids_limit`. | Resource controls beyond supported `mem_limit`. |
| User, security, and device access | `group_add`, `security_opt`, `privileged`, `credential_spec`, `device_cgroup_rules`, `devices`, `gpus`. | Supplemental groups, security options, privileged mode, Windows credential specs, host devices, cgroup device rules, and GPU device requests. |
| DNS and kernel tuning | `dns_opt`, `sysctls`. | DNS resolver options and per-container sysctl support. |
| Health and completion conditions | `healthcheck`, `depends_on` conditions `service_healthy` and `service_completed_successfully`. | Health status, exit code, and completion-time inspection. |
| Config and secret mounts | Service-level `configs` and `secrets`. | Compose-style config/secret mount primitives. |
| Runtime restart policy | Service `restart`. | Docker-compatible restart policies. |
| Runtime CLI data | `top`, `events`, `port`, `pause`, `unpause`, `wait`. | Process listing, event stream, richer published-port inspect output, pause/unpause, and wait/exit metadata. |
| Legacy links | `links`, `external_links`. | Legacy alias/link behavior and host-entry semantics. |

## Blocked By `container-compose`

These surfaces need more plugin implementation, more validation, or an explicit
security/design decision in this repository. Some may later uncover Apple
runtime gaps, but the first known blocker is `container-compose`.

| Compose v2 surface | Current behavior | Why this is a plugin gap |
| --- | --- | --- |
| Service replica scaling | Explicit `scale` and `deploy.replicas` values other than `1` fail before side effects. | The plugin currently manages one deterministic container per service. Multi-replica naming, reconciliation, logs, ps, rm, and DNS semantics are not implemented yet. |
| Advanced build fields | Explicitly rejected before side effects when configured. | Only `context`, `dockerfile`, `args`, and `target` are mapped today. Build fields such as additional contexts, cache exporters/importers, build labels, platforms, secrets, SSH, tags, and provenance need runtime mapping work. |
| Compose Deploy Specification beyond replica count | Explicitly rejected before side effects when configured. | Swarm-style `deploy` mode, placement, update, rollback, endpoint, labels, restart policy, and resource limits/reservations are outside the current local workflow mapping. |
| Develop/watch workflow | Explicitly rejected before side effects when configured. | `develop`, `watch`, sync/rebuild actions, and file-watch semantics need plugin work before they can affect managed containers. |
| Provider, service model, and lifecycle hook surfaces | Explicitly rejected before side effects when configured on a service. | `provider`, service-level `models`, `post_start`, and `pre_stop` need orchestration design before they can affect managed containers. |
| Service metadata and logging surfaces | Explicitly rejected before side effects when Compose v2 accepts the field. | `annotations`, `attach`, `label_file`, `logging`, and `storage_opt` need runtime mapping before they can affect managed containers. Legacy `log_driver` and `log_opt` are rejected by the Compose v2 schema during normalization, with defensive validation if they appear in canonical JSON. |
| Volume inheritance and driver shortcuts | Explicitly rejected before side effects when Compose v2 accepts the field. | `volumes_from` needs plugin behavior before it can affect managed containers. Legacy service-level `volume_driver` is rejected by the Compose v2 schema during normalization, with defensive validation if it appears in canonical JSON. |
| API socket mounting | Explicitly rejected before side effects when enabled. | `use_api_socket` needs a security review and runtime mapping before the plugin can mount an API socket into managed containers. |
| Block I/O controls | Explicitly rejected before side effects when configured. | `blkio_config` needs a runtime primitive assessment before block I/O weights and throttle-device limits can affect managed containers. |
| Unsupported service pull policies | Unsupported values fail before side effects. | The plugin currently supports only `always`, `missing`, `if_not_present`, and `never`; values such as `build`, `daily`, `weekly`, and time windows need separate semantics. |
| Additional Docker Compose CLI commands and flags | Not implemented unless listed in the supported table. | Commands such as `create`, `ls`, `watch`, `stats`, `scale`, `attach`, `commit`, `convert`, `export`, `publish`, `volumes`, and advanced flags on supported commands need separate command work. |

## Config-Only Surfaces

These surfaces are normalized and preserved because they are useful in
`container compose config` output or harmless as metadata, but they do not
currently change runtime orchestration.

| Compose v2 surface | Current behavior |
| --- | --- |
| Service `expose` | Preserved in normalized config; no runtime port publishing is performed. Use `ports` for host publishing. |
| Extension fields | Project and service `x-*` fields are preserved in normalized config. |
| Top-level `configs` and `secrets` definitions | Preserved in normalized config. Service-level use is rejected because mounting them needs runtime support. |
| Top-level `models` definitions | Preserved in normalized config. Service-level model bindings are rejected because model runtime wiring is not implemented. |

## Examples

Each example includes a `compose.yaml` and at least one matching `Dockerfile`.
Unsupported examples are still valid Docker Compose v2 projects; they fail here
before side effects because either Apple `container` or `container-compose` is
missing the necessary behavior.

### Supported Example

This project uses supported local-development surfaces: build, image pull
policy, ports, environment, one network, one named volume, CPU/memory limits,
stop behavior, and simple `service_started` dependency ordering.

```yaml
# compose.yaml
name: supported-demo

services:
  api:
    build:
      context: ./api
      dockerfile: Dockerfile
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
RUN mkdir -p /app && printf '%s\n' "$APP_ENV" > /app/env.txt
CMD ["sh", "-c", "sleep 3600"]
```

### Apple Gap Example: Network Attachment

This project is valid Docker Compose v2, but `container-compose up` rejects it
before creating resources because Apple `container` cannot attach one container
to multiple networks with aliases and attachment options.

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

### Apple Gap Example: Health, Secrets, And Restart

This project is valid Docker Compose v2, but the service health gate, secret
mount, and restart policy need runtime primitives that Apple `container` does
not expose yet.

```yaml
# compose.yaml
name: apple-health-gap-demo

services:
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
# api/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "touch /tmp/ready && sleep 3600"]
```

```dockerfile
# worker/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "echo worker-ready && sleep 3600"]
```

### `container-compose` Gap Example: Replica Scaling

This project is valid Docker Compose v2, and Apple `container` can create
multiple containers in general, but this plugin does not yet implement Docker
Compose replica semantics. It fails before side effects.

```yaml
# compose.yaml
name: plugin-scale-gap-demo

services:
  worker:
    build:
      context: ./worker
    scale: 3
```

```dockerfile
# worker/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
```

### `container-compose` Gap Example: Advanced Build Fields

This project is valid Docker Compose v2, but build cache wiring and build
secret handling are plugin work. It fails before any `container build` command
is emitted.

```yaml
# compose.yaml
name: plugin-build-gap-demo

services:
  api:
    build:
      context: ./api
      dockerfile: Dockerfile
      cache_from:
        - type=registry,ref=example/api:cache
      secrets:
        - npm_token

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

### `container-compose` Gap Example: Provider And Lifecycle Hooks

This project is valid Docker Compose v2, but service providers, service-level
model bindings, and lifecycle hooks need plugin orchestration design before they
can run safely. It fails before side effects.

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
```

```dockerfile
# api/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

### `container-compose` Gap Example: Develop Watch

This project is valid Docker Compose v2, but file watching, sync, and rebuild
orchestration are plugin work. It fails before side effects.

```yaml
# compose.yaml
name: plugin-develop-gap-demo

services:
  api:
    build:
      context: ./api
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

### Config-Only Example

This project keeps extension metadata, top-level model metadata, and `expose`
in config output. Runtime startup ignores the metadata and does not publish
`expose` to the host.

```yaml
# compose.yaml
name: config-only-demo

x-owner: platform

models:
  llm:
    model: example/local-llm

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

When a change adds, removes, or changes a Compose-to-`container` runtime
mapping, update this file in the same commit or pull request. Do not mark a
primitive as supported until the orchestrator maps it, rejects unsupported
alternatives clearly, and has focused test coverage.
