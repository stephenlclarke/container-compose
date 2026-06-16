# Compatibility

`container-compose` targets local-development Docker Compose v2 workflows where Apple's [`container`](https://github.com/apple/container) CLI exposes matching runtime primitives. This file is the support matrix for those primitives and must be updated in the same change whenever runtime orchestration behavior changes.

## Reference Implementations

- Docker Compose v2 implementation: [`docker/compose`](https://github.com/docker/compose).
- Docker Compose v2 Go API package: [`github.com/docker/compose/v2/pkg/api`](https://pkg.go.dev/github.com/docker/compose/v2/pkg/api).

## Supported Runtime Primitives

| Compose area | Supported behavior | `container` primitive |
| --- | --- | --- |
| Image build | Builds services with `build`, including context, Dockerfile, target, build args, `--no-cache`, explicit image tags, and generated tags for build-only services. | `container build` |
| Image pull | Pulls service images directly and supports `up --pull always`, `up --pull missing`, `up --pull never`, and service `pull_policy` values `always`, `missing`, `if_not_present`, and `never`. | `container image pull`, `container image inspect` |
| Image push | Pushes selected service images. | `container image push` |
| Container startup | Creates service containers through deterministic `run` arguments, with detached `up` by default and attached `run` for one-off containers. | `container run` |
| Container naming | Uses deterministic project-service names, honors explicit service `container_name` for managed service containers, and generates unique one-off names for `run`. | `container run --name` |
| Container lifecycle | Starts, stops, restarts, removes, and kills selected service containers. | `container start`, `container stop`, `container delete`, `container kill` |
| Container inspection | Reads existing service containers to compare Compose config hashes before deciding whether to recreate. | `container inspect` |
| Container listing | Lists project containers and filters them client-side by Compose project labels. | `container list --format json` |
| Container logs | Reads service logs with follow and tail options. | `container logs` |
| Container exec | Executes commands in existing service containers with optional interactive and TTY flags. | `container exec` |
| File copy | Copies files to or from containers using the underlying runtime command. | `container cp` |
| Networks | Creates and deletes non-external project networks, reuses external network names, and attaches a service to one network. | `container network create`, `container network delete`, `container run --network` |
| Volumes | Creates and deletes non-external named volumes, reuses external volume names, and mounts named, bind, tmpfs, read-only, and stable anonymous volume arguments. | `container volume create`, `container volume delete`, `container run --volume`, `container run --tmpfs` |
| Environment | Passes environment variables and service env files through to the runtime. | `container run --env`, `container run --env-file` |
| Ports | Publishes normalized Compose port strings. | `container run --publish` |
| Process options | Maps service command, entrypoint, working directory, user, TTY, stdin, read-only root filesystem, init, platform, runtime handler, DNS, DNS search, Linux capabilities, memory limit, CPU limit, shared-memory size, and ulimits. | `container run` flags |
| Labels | Adds deterministic Compose labels for project, service, one-off state, working directory, config-file hash, and config hash, plus service and resource labels. | `container run --label`, `container network create --label`, `container volume create --label` |
| Dependency order | Starts selected services after dependencies when the dependency condition is `service_started` or omitted. | Orchestrator ordering before `container run` |
| Reconciliation | Reuses, recreates, or removes containers based on config hash, `--force-recreate`, `--no-recreate`, and `--remove-orphans`. | `container inspect`, `container stop`, `container delete`, `container list` |
| Stop behavior | Applies service stop signal and grace-period seconds when Compose-managed service containers are stopped, restarted, removed with `--stop`, recreated, or torn down. | `container stop --signal`, `container stop --time` |
| Project teardown | Stops and deletes project service containers, deletes non-external networks, and deletes volumes only when `down --volumes` is used. | `container stop`, `container delete`, `container network delete`, `container volume delete` |

## Config-Only Semantics

These Compose model fields are normalized and preserved for `compose config`, but do not currently have matching runtime orchestration:

- Service `expose` entries.
- Project and service extension fields such as `x-*`.
- Top-level `configs` and `secrets` definitions.

## Explicit Runtime Gaps

These fields currently fail before runtime side effects because the equivalent local runtime primitive is not available or not wired yet:

- Multiple service networks.
- Network aliases.
- Service network attachment options including `driver_opts`, `gw_priority`,
  `interface_name`, `ipv4_address`, `ipv6_address`, `link_local_ips`,
  `mac_address`, and `priority`.
- `network_mode`.
- `cgroup` and `cgroup_parent`.
- `ipc`, `pid`, `userns_mode`, and `uts`.
- `isolation`.
- `mac_address`.
- `dns_opt`.
- `sysctls`.
- `domainname`.
- `links` and `external_links`.
- `depends_on` conditions other than `service_started`.
- `extra_hosts`.
- `hostname`.
- `healthcheck`.
- Service `configs`.
- Service `secrets`.
- `privileged`.
- Service `pull_policy` values that require build or refresh semantics.
- Runtime restart policies through service `restart`.
- `top`, `events`, `port`, `pause`, `unpause`, and `wait` subcommands.

## Maintenance Rule

When a change adds, removes, or changes a Compose-to-`container` runtime mapping, update this file in the same commit or pull request. Do not mark a primitive as supported until the orchestrator maps it, rejects unsupported alternatives clearly, and has focused test coverage.
