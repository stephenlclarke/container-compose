# Compatibility

`container-compose` targets local-development Docker Compose v2 workflows where Apple's [`container`](https://github.com/apple/container) CLI exposes matching runtime primitives. This file explains what works today, what is blocked by Apple `container`, what is still missing in [`stephenlclarke/container-compose`](https://github.com/stephenlclarke/container-compose), and what is preserved only for `compose config`.

## References

- Compose file reference: [docs.docker.com/reference/compose-file](https://docs.docker.com/reference/compose-file/).
- Docker Compose v2 CLI reference: [docs.docker.com/reference/cli/docker/compose](https://docs.docker.com/reference/cli/docker/compose/).
- Docker Compose v2 implementation: [`docker/compose`](https://github.com/docker/compose).
- Docker Compose v2 Go API package: [`github.com/docker/compose/v2/pkg/api`](https://pkg.go.dev/github.com/docker/compose/v2/pkg/api).
- Compose model normalizer used here: [`compose-spec/compose-go`](https://github.com/compose-spec/compose-go).

## Status Labels

| Status | Meaning | Expected behavior |
| --- | --- | --- |
| Supported | `container-compose` maps the Compose surface to an available Apple `container` primitive. | Commands run, and focused tests cover the mapping. |
| Apple `container` gap | `container-compose` recognizes the Compose surface, but Apple `container` does not expose the required local runtime primitive yet. | Commands fail before runtime side effects with a message naming the unsupported feature. |
| container-compose gap | Apple `container` either has enough low-level primitives or the behavior is local orchestration work, but this plugin has not implemented the Compose semantics yet. | Commands fail when validation exists. Some older gaps are listed as known follow-up work until validators are added. |
| Config-only | The surface is preserved for normalized config output or is harmless metadata, but it does not affect runtime orchestration. | `compose config` preserves it; runtime commands ignore it intentionally. |

## Supported Surfaces

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

### Supported Example

This Compose file uses supported local-development surfaces: build, image pull policy, ports, environment, one network, one named volume, CPU/memory limits, stop behavior, and simple `service_started` dependency ordering.

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
RUN printf '%s\n' "$APP_ENV" > /app-env.txt
CMD ["sh", "-c", "sleep 3600"]
```

## Unsupported Because Apple `container` Lacks a Primitive

These surfaces are recognized or planned by `container-compose`, but the current Apple `container` CLI/API does not expose enough runtime behavior to implement Docker Compose semantics faithfully.

| Compose v2 surface | Examples | Missing Apple `container` primitive |
| --- | --- | --- |
| Multiple service networks | Two or more entries under service `networks`. | Post-create network connect and multi-network attachment. |
| Service network aliases and attachment options | `aliases`, `driver_opts`, `gw_priority`, `interface_name`, `ipv4_address`, `ipv6_address`, `link_local_ips`, service-level network `mac_address`, `priority`. | Network aliasing and rich network attachment configuration. |
| `network_mode` | `host`, `none`, `service:api`, `container:name`. | Docker-compatible network namespace modes. |
| Hostname and host table controls | `hostname`, `domainname`, `extra_hosts`, service `mac_address`. | Explicit host entries, custom hostname/domain name, and MAC address support. |
| Namespace and isolation controls | `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, `isolation`. | Namespace selection and parent cgroup controls. |
| Advanced CPU controls | `cpu_count`, `cpu_percent`, `cpu_period`, `cpu_quota`, `cpu_rt_period`, `cpu_rt_runtime`, `cpuset`, `cpu_shares`. | CPU scheduler controls beyond supported `cpus`. |
| Advanced memory, OOM, and PID controls | `mem_reservation`, `memswap_limit`, `mem_swappiness`, `oom_kill_disable`, `oom_score_adj`, `pids_limit`. | Resource controls beyond supported `mem_limit`. |
| User, security, and device access | `group_add`, `security_opt`, `privileged`, `credential_spec`, `device_cgroup_rules`, `devices`, `gpus`. | Supplemental groups, security options, privileged mode, Windows credential specs, host devices, cgroup device rules, and GPU device requests. |
| DNS and kernel tuning | `dns_opt`, `sysctls`. | DNS resolver options and per-container sysctl support. |
| Health and completion conditions | `healthcheck`, `depends_on` conditions `service_healthy` and `service_completed_successfully`. | Health status, exit code, and completion-time inspection. |
| Config and secret mounts | Service-level `configs` and `secrets`. | Compose-style config/secret mount primitives. |
| Runtime restart policy | Service `restart`. | Docker-compatible restart policies. |
| Unsupported command surfaces | `top`, `events`, `port`, `pause`, `unpause`, `wait`. | Process listing, event stream, richer published-port inspect output, pause/unpause, and wait/exit metadata. |
| Legacy links | `links`, `external_links`. | Legacy alias/link behavior and host-entry semantics. |

### Apple `container` Gap Example

This project is valid Docker Compose v2, but `container-compose up` must reject it before creating resources because Apple `container` cannot attach one container to two networks with aliases.

```yaml
# compose.yaml
name: apple-runtime-gap-demo

services:
  api:
    build:
      context: ./api
    networks:
      app:
        aliases:
          - api.internal
      admin: {}

networks:
  app: {}
  admin: {}
```

```dockerfile
# api/Dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

## Unsupported By container-compose Today

These surfaces are Docker Compose v2 features that need more plugin orchestration or validation work in [`stephenlclarke/container-compose`](https://github.com/stephenlclarke/container-compose). Some may also need Apple runtime improvements later, but the first blocker is this plugin.

| Compose v2 surface | Current status | Notes |
| --- | --- | --- |
| Service replica scaling | Explicit `scale` and `deploy.replicas` values other than `1` fail before side effects. | The plugin currently manages one deterministic container per service. Multi-replica naming, reconciliation, logs, ps, rm, and DNS semantics are not implemented yet. |
| Advanced build fields | Not fully implemented. | Only `context`, `dockerfile`, `args`, and `target` are mapped today. Build fields such as additional contexts, cache exporters/importers, build labels, platforms, secrets, SSH, tags, and provenance need follow-up work. |
| Compose Deploy Specification beyond replica count | Not implemented. | Swarm-style `deploy` placement, update, rollback, endpoint, labels, and most resource reservation fields are outside the current local workflow mapping. |
| Develop/watch workflow | Not implemented. | `develop`, `watch`, sync/rebuild actions, and file-watch semantics need plugin work. |
| Provider, model, and lifecycle hook surfaces | Not implemented. | `provider`, `models`, `post_start`, and `pre_stop` are not orchestrated. |
| Service metadata and logging surfaces | Explicitly rejected before side effects when Compose v2 accepts the field. | `annotations`, `attach`, `label_file`, `logging`, and `storage_opt` need runtime mapping before they can affect managed containers. Legacy `log_driver` and `log_opt` are rejected by the Compose v2 schema during normalization, with defensive validation if they appear in canonical JSON. |
| Volume inheritance and driver shortcuts | Explicitly rejected before side effects when Compose v2 accepts the field. | `volumes_from` needs plugin behavior before it can affect managed containers. Legacy service-level `volume_driver` is rejected by the Compose v2 schema during normalization, with defensive validation if it appears in canonical JSON. |
| API socket mounting | Not implemented. | `use_api_socket` needs a security review and runtime mapping. |
| Block I/O controls | Not implemented. | `blkio_config` needs validation and a runtime primitive assessment. |
| Additional Docker Compose CLI commands and flags | Not implemented. | Commands outside the current plugin command tree, such as `create`, `ls`, `watch`, and advanced flags on supported commands, need separate work. |

### container-compose Gap Example

This project is valid Docker Compose v2, and Apple `container` can create multiple containers in general, but this plugin does not yet implement Docker Compose replica semantics. It fails before side effects.

```yaml
# compose.yaml
name: plugin-gap-demo

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

## Config-Only Surfaces

These surfaces are normalized and preserved because they are useful in `compose config` output or harmless as metadata, but they do not currently change runtime orchestration.

| Compose v2 surface | Current behavior |
| --- | --- |
| Service `expose` | Preserved in normalized config; no runtime port publishing is performed. Use `ports` for host publishing. |
| Extension fields | Project and service `x-*` fields are preserved in normalized config. |
| Top-level `configs` and `secrets` definitions | Preserved in normalized config. Service-level use is rejected because mounting them needs runtime support. |

### Config-Only Example

This project keeps extension metadata and `expose` in config output. Runtime startup ignores the metadata and does not publish `expose` to the host.

```yaml
# compose.yaml
name: config-only-demo

x-owner: platform

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
