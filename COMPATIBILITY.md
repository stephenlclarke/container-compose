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

### Supported

Docker Compose v2 accepts the surface, [`apple/container`][apple-container] exposes the needed primitive, and `container-compose` maps it. Runtime work executes through [`apple/container`][apple-container] APIs or CLI commands. No compatibility fix is needed.

### [`apple/container`][apple-container] Gap

Docker Compose v2 accepts the surface, but [`apple/container`][apple-container] is missing the primitive, has incomplete behavior, or does not expose the behavior through a usable API. `container-compose` rejects the field before resources are created with an `apple/container` runtime gap message. The fix starts upstream in [`apple/container`][apple-container], then this repo maps the new primitive.

### `container-compose` Gap

Docker Compose v2 accepts the surface and [`apple/container`][apple-container] is not known to be the first blocker, but this plugin does not map it yet. `container-compose` rejects the field before resources are created with a plugin implementation message. The fix belongs in this repository.

### Config-Only

Docker Compose v2 accepts the surface and runtime support is not needed for normalized `config` output. `container-compose` preserves the data for `config` and `convert`; runtime commands either ignore harmless metadata or reject service-level use when runtime behavior is requested.

## Support Matrix

Each entry below is written as a compact status card:

- **Compose surface:** The Compose v2 fields or CLI commands covered by the row.
- **Apple/container path:** The runtime API or CLI primitive that can implement it, or the missing primitive that blocks it.
- **container-compose status:** What this plugin does today.
- **Examples:** Links to runnable examples later in this file.

### Supported By apple/container And container-compose

These surfaces have all three pieces: Docker Compose v2 model support, [`apple/container`][apple-container] runtime support, and plugin orchestration.

#### Config normalization

- **Compose surface:**
  - File discovery, repeated `-f`, `.env`, `--env-file`, interpolation, merge, profiles, `--project-directory`, and `-p/--project-name`.
  - Canonical `config` and `convert` JSON.
- **Apple/container path:** No runtime primitive is needed.
- **container-compose status:** Supported through `compose-go` normalization.
- **Examples:** [S1](#s1-supported-local-web-stack), [O1](#o1-config-only-metadata).

#### Build and images

- **Compose surface:**
  - Build inputs: `build.context`, `build.dockerfile`, `build.dockerfile_inline`, `build.args`, `build.cache_from`, `build.cache_to`, `build.labels`, `build.platforms`, `build.target`, `build.no_cache`, `build.pull`, `build.tags`, and file-backed or environment-backed `build.secrets`.
  - Build commands: `build --no-cache`, `build --pull`, `build --push`, `build --quiet/-q`, and `build --with-dependencies`.
  - Image commands: `pull`, `push`, `images`, and image removal through `down --rmi local/all`.
  - Pull policies: global `up --pull`, `create --pull`, one-off `run --pull`, and service `pull_policy` values `always`, `missing`, `if_not_present`, `never`, `build`, `daily`, `weekly`, and `every_<duration>`.
- **Apple/container path:**
  - Build runs through `container build --pull --quiet --platform --cache-in --cache-out --tag --label --secret --file`.
  - Image operations use direct `ClientImage.pull`, `ClientImage.get`, `ClientImage.push`, `ClientImage.delete`, `ClientImage.cleanUpOrphanedBlobs()`, and project discovery through `ContainerClient.list(filters:)`.
  - `build.dockerfile_inline` is materialized to a temporary Dockerfile.
- **container-compose status:** Supported for the listed local-development subset.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Container lifecycle

- **Compose surface:**
  - Project lifecycle: `create`, `up`, `down`, `start`, `stop`, `restart`, `rm`, `kill`, and `wait`.
  - Reconciliation: deterministic names, indexed replicas, one-off names, config-hash recreate, `--force-recreate`, `--no-recreate`, `--remove-orphans`, and `down --rmi local/all`.
  - Scaling: `up --scale`, `create --scale`, standalone `scale`, `scale --no-deps`, service `scale`, and local `deploy.replicas`.
  - Options: `up --no-start`, `up --always-recreate-deps`, timeouts, service `attach: false`, `rm --force/-f`, `wait --down-project`, `run --rm`, `run --detach/-d`, and `run --name`.
- **Apple/container path:** `container create`, `container run`, `ContainerClient.bootstrap`, `ClientProcess.start`, `ClientProcess.wait`, `ContainerClient.get`, `ContainerClient.list`, `ContainerClient.stop`, `ContainerClient.delete`, and `ContainerClient.kill`.
- **container-compose status:** Supported for running or stopping service containers. Already-stopped wait replay remains an Apple/container runtime gap.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Project discovery

- **Compose surface:** `ls`, `ls --all/-a`, `ls --format table/json`, `ls --quiet/-q`, and `ls --filter name=...`.
- **Apple/container path:** `ContainerClient.list(filters:)` and Compose project/config-hash labels.
- **container-compose status:** Supported from labels on created containers.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Container interaction

- **Compose surface:**
  - Discovery and output: `ps`, filtered `ps`, `logs`, indexed `logs`, harmless `logs --no-color` and `logs --no-log-prefix`, output-only `attach --no-stdin --sig-proxy=false`, and indexed attach.
  - Exec: default stdin/TTY behavior, `-T/--no-tty`, `--interactive=false`, detached exec, env/user/workdir overrides, and indexed service targets.
  - File movement: service-aware `cp`, service-to-service `cp`, indexed `cp`, `cp --all`, one-off copy target discovery, and `export`.
  - Runtime queries: explicit published-port `port`, indexed `port`, `stats`, `stats --all`, `stats --format table/json`, `stats --no-stream`, and `version`.
- **Apple/container path:** Direct `ContainerClient` list/get/logs/copy/export/stats APIs, `ProcessIO`, `ContainerClient.createProcess`, and `ClientProcess.start`.
- **container-compose status:** Supported for the listed direct API paths. Rich log filtering and runtime process/event controls remain Apple/container gaps.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Develop dry-run planning

- **Compose surface:** `watch --dry-run`, `watch --no-up`, `watch --no-prune`, `watch --quiet`, selected services, and normalized `develop.watch` triggers.
- **Apple/container path:** No runtime mutation. The dry-run path validates Compose trigger metadata and prints the planned watch settings/actions.
- **container-compose status:** Supported for dry-run planning only. Live file watching, sync/rebuild/restart action execution, and `sync+exec` execution remain plugin work.
- **Example:** [C3](#c3-plugin-gap-develop-providers-models-and-hooks).

#### Default networking

- **Compose surface:**
  - One service network, default project networks, external networks, `network_mode: none`, project network `internal`, and one IPv4 plus one IPv6 project network IPAM `subnet`.
  - Explicit host-published ports for `create`, `up`, and one-off `run`.
  - Scaled published-port ranges with enough explicit host ports for every replica.
  - Single-network `mac_address` and MTU through `driver_opts.com.docker.network.driver.mtu`.
- **Apple/container path:** Direct `NetworkClient.create`, `NetworkConfiguration`, `NetworkClient.delete`, plus supported `container create/run --network` and `--publish` flags where a direct adapter is not available yet.
- **container-compose status:** Supported for the listed single-network local subset.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Default storage

- **Compose surface:**
  - Named volumes, external volumes, bind mounts, read-only mounts, anonymous volumes, and deterministic per-replica anonymous volume names.
  - Top-level volume `driver`, `driver_opts`, and `labels`.
  - Tmpfs mounts, including long-form `tmpfs.size` and `tmpfs.mode`.
  - Same-project `volumes_from` for declared Compose mounts with `ro`/`rw` overrides.
  - One-off `run --volume/-v`, runtime-scoped `volumes`, quiet/json volume output, `rm --volumes/-v`, and `down --volumes`.
- **Apple/container path:** Direct `ClientVolume.create`, `ClientVolume.list`, and `ClientVolume.delete`, plus supported `container create/run --volume`, `--tmpfs`, and `--mount type=tmpfs` flags.
- **container-compose status:** Supported for declared Compose mounts and project-scoped volumes.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Common runtime options

- **Compose surface:**
  - Process options: `command`, `entrypoint`, one-off `run --entrypoint`, `working_dir`, one-off `run --workdir`, `user`, one-off `run --user`, `tty`, one-off `run -T/--no-tty`, and `stdin_open`.
  - Runtime options: `container_name`, `read_only`, `init`, `platform`, `runtime`, DNS settings, capabilities, CPU/memory local limits, `shm_size`, `ulimits`, `stop_signal`, and `stop_grace_period`.
- **Apple/container path:** Supported `container create/run` flags and `ContainerClient.stop(id:opts:)`.
- **container-compose status:** Supported for the listed local-development runtime options.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Environment and metadata

- **Compose surface:** Service `environment`, `env_file`, one-off env and label flags, service labels, service annotations, `label_file`, network labels, volume labels, and Compose project/service/config-hash labels.
- **Apple/container path:** Supported `container create/run --env`, `--env-file`, and resource/container labels.
- **container-compose status:** Supported. Service annotations are mapped to runtime metadata labels.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Simple ordering

- **Compose surface:** `depends_on` with no condition or `condition: service_started`, same-project `volumes_from` implicit dependencies, optional dependencies, `depends_on.<service>.restart: true` for single-replica restarts, `up --always-recreate-deps`, `up --no-deps`, and `run --no-deps`.
- **Apple/container path:** Plugin dependency ordering, dependency-change tracking, `ContainerClient.stop(id:opts:)`, and `ContainerClient.start(id:)`.
- **container-compose status:** Supported for service-started ordering and selected dependency traversal behavior.
- **Example:** [S1](#s1-supported-local-web-stack).

### Blocked By apple/container

These are valid Docker Compose v2 surfaces. `container-compose` recognizes them, but [`apple/container`][apple-container] does not expose a Docker Compose compatible runtime primitive yet.

#### Rich network attachment and IPAM controls

- **Compose surface:** Multiple service networks, aliases, service-name DNS for replicas, fixed addresses, network priority/interface fields, `network_mode` values other than `none`, and richer project IPAM fields.
- **Missing Apple/container primitive:** Multi-network attach/connect, per-network aliases/options beyond MAC and MTU, multi-record DNS lookup for scaled service names, fixed addresses, Docker-compatible namespace modes, and richer project network IPAM controls.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A1](#a1-apple-gap-networking).

#### Host identity and legacy links

- **Compose surface:** `hostname`, `domainname`, `extra_hosts`, `links`, and `external_links`.
- **Missing Apple/container primitive:** Hostname/domain controls, explicit host entries, and legacy link/alias semantics.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A2](#a2-apple-gap-host-identity-and-links).

#### Namespace and resource controls

- **Compose surface:** `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, `isolation`, CPU scheduler controls beyond supported `cpus`, and memory/OOM/PID controls beyond supported `mem_limit`.
- **Missing Apple/container primitive:** Namespace selection, parent cgroups, CPU scheduler controls beyond `cpus`, memory controls beyond `mem_limit`, and swap/OOM/PID controls.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A3](#a3-apple-gap-runtime-controls).

#### User, security, devices, and kernel tuning

- **Compose surface:** `group_add`, `security_opt`, service `privileged`, `exec --privileged`, `credential_spec`, `device_cgroup_rules`, `devices`, `gpus`, and `sysctls`.
- **Missing Apple/container primitive:** Supplemental groups, security profiles beyond supported `cap_add`/`cap_drop`, privileged mode, host devices, GPUs, per-container sysctls, and privileged exec processes.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A3](#a3-apple-gap-runtime-controls).

#### Health, completion, configs, secrets, service restart

- **Compose surface:** `healthcheck`, `depends_on.condition: service_healthy`, `depends_on.condition: service_completed_successfully`, service-level `configs`, service-level `secrets`, and service `restart`.
- **Missing Apple/container primitive:** Health status, exit code/completion-time metadata, config/secret mount primitives, and restart policy support.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A4](#a4-apple-gap-health-secrets-and-restart).

#### Advanced build configuration

- **Compose surface:** `additional_contexts`, `entitlements`, build `extra_hosts`, build `isolation`, build `network`, build `privileged`, `provenance`, `sbom`, unsupported build secret forms and metadata, build `shm_size`, `ssh`, and build `ulimits`.
- **Missing Apple/container primitive:** Docker Compose compatible BuildKit inputs for additional contexts, build host entries, build network modes, isolation, privileged builds, entitlements, SSH forwarding, advanced build secret metadata, build shared memory, build ulimits, and provenance/SBOM attestations.
- **container-compose status:** Rejected before `container build` is invoked.
- **Example:** [A6](#a6-apple-gap-advanced-build-fields).

#### Runtime data and dynamic port commands

- **Compose surface:** Target-only `ports` such as `"80"` or `"8080"`, `top`, `events`, `pause`, `unpause`, already-stopped `wait` exit-code replay, `cp --archive`, and `cp --follow-link`.
- **Missing Apple/container primitive:** Dynamic host-port allocation, process listing, event stream, pause/unpause, stored process exit codes after container stop, and copy archive/follow-link controls.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A5](#a5-apple-gap-runtime-data-commands).

#### Image commit and Compose application publishing

- **Compose surface:** `commit`, `publish`, and `oci://` Compose application references.
- **Missing Apple/container primitive:** Container-to-image commit snapshots with image metadata, plus Compose application OCI artifact publishing and consumption.
- **container-compose status:** Command names are exposed so Docker Compose v2 scripts get precise unsupported-feature errors instead of unknown-command failures.
- **Example:** [A7](#a7-apple-gap-image-commit-and-compose-publish).

### Blocked By `container-compose`

These are valid Docker Compose v2 surfaces where [`apple/container`][apple-container] is not known to be the first blocker. The missing design, orchestration, or safety policy belongs in this repository.

#### Local deploy handling

- **Compose surface:** Deploy fields beyond local replica count and CPU/memory limits.
- **Apple/container path:** Not known to be the first blocker.
- **Missing plugin work:** A local interpretation of broader deploy semantics.
- **Example:** [C1](#c1-plugin-gap-replica-scaling-edge-cases-and-deploy).

#### Develop, providers, models, hooks

- **Compose surface:** `develop.watch`, service `provider`, service `models`, `post_start`, and `pre_stop`.
- **Apple/container path:** Not known to be the first blocker.
- **Missing plugin work:** File-watch loops, sync/rebuild/restart action execution, provider/model wiring, and lifecycle hook safety and ordering.
- **Example:** [C3](#c3-plugin-gap-develop-providers-models-and-hooks).

#### Metadata, logging, storage shortcuts

- **Compose surface:** `logging`, `log_driver`, `log_opt`, `storage_opt`, external `volumes_from`, image-declared inherited mounts, service-level `volume_driver`, advanced service volume options, image mounts, and mount consistency.
- **Apple/container path:** Not known to be the first blocker for every field, though richer log/storage runtime APIs may later be needed upstream.
- **Missing plugin work:** Runtime mapping, external/inferred inherited mount behavior, logging behavior, storage option handling, and advanced mount policy.
- **Example:** [C4](#c4-plugin-gap-metadata-storage-and-api-socket).

#### API socket and block I/O

- **Compose surface:** `use_api_socket` and `blkio_config`.
- **Apple/container path:** Not known to be the first blocker.
- **Missing plugin work:** Security review and resource-control mapping.
- **Example:** [C4](#c4-plugin-gap-metadata-storage-and-api-socket).

#### Additional CLI command behavior

- **Compose surface:** Default stdin/signal-proxy `attach`.
- **Apple/container path:** Output-only logs are available today; an interactive attach path may later need runtime support depending on the final design.
- **Missing plugin work:** Interactive command design, stdin forwarding, signal-proxy behavior, and detach-key compatibility.
- **Example:** [C5](#c5-plugin-gap-additional-cli-commands).

### Config-Only Today

These Compose surfaces are useful in normalized output, but they do not currently change runtime orchestration.

#### Top-level and service `x-*` extensions

- **Current behavior:** Preserved by `container compose config` and `container compose convert`; no runtime behavior by itself.
- **Example:** [O1](#o1-config-only-metadata).

#### Service `expose`

- **Current behavior:** Preserved by `config` and `convert`; it does not publish host ports. Use `ports` for host publishing.
- **Example:** [O1](#o1-config-only-metadata).

#### Top-level `configs` and `secrets` definitions

- **Current behavior:** Preserved by `config` and `convert`. File-backed and environment-backed secrets can feed supported `build.secrets`.
- **Runtime boundary:** Service-level consumption is an [`apple/container`][apple-container] gap because mounts need runtime support.
- **Examples:** [S1](#s1-supported-local-web-stack), [O1](#o1-config-only-metadata), [A4](#a4-apple-gap-health-secrets-and-restart).

#### Top-level `models` definitions

- **Current behavior:** Preserved by `config` and `convert`.
- **Runtime boundary:** Service-level model bindings are a plugin gap.
- **Examples:** [O1](#o1-config-only-metadata), [C3](#c3-plugin-gap-develop-providers-models-and-hooks).

## CLI Command Status

### Supported Commands

- Config and project: `config`, `convert`, and `ls`.
- Lifecycle: `create`, `up`, `scale`, `down`, `run`, `start`, `stop`, `restart`, `rm`, `kill`, and running/stopping-container `wait`.
- Build and image: `build`, `pull`, `push`, `images`, and `down --rmi`.
- Interaction: `ps`, `logs`, output-only `attach --no-stdin --sig-proxy=false`, `exec`, `cp`, `export`, explicit published-port `port`, `stats`, `stats --no-trunc`, and `version`.
- Supported option families include indexed service targets, quiet/json/table output where listed above, explicit published ports, `--scale`, `--timeout`, `--no-build`, `--quiet-build`, `--quiet-pull`, `--no-start`, `--always-recreate-deps`, `--include-deps`, `--ignore-buildable`, `--ignore-pull-failures`, `--ignore-push-failures`, and `--down-project` for running/stopping service containers.

### Commands Blocked By [`apple/container`][apple-container] Runtime Gaps

- Dynamic host-port allocation.
- `top`, `events`, `pause`, and `unpause`.
- Already-stopped `wait` exit-code replay.
- `cp --archive` and `cp --follow-link`.
- `commit` container image snapshots.
- `publish` Compose application OCI artifacts and `oci://` Compose file consumption.

### Commands Blocked By `container-compose` Design Gaps

- `watch` file-watch/action execution.
- Default stdin/signal-proxy `attach`.

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

- [S1: Supported Local Web Stack](#s1-supported-local-web-stack): Supported. Demonstrates build, images, `create`, ports, static `port`, environment, one network, no-network services, single-network MAC addresses, volume mounts, `volumes`, labels, `label_file`, lifecycle, logs, exec, stats, copy, and `down --volumes`.
- [A1: Apple Gap, Networking](#a1-apple-gap-networking): [`apple/container`][apple-container] gap. Demonstrates multiple networks, aliases, service-name DNS for replicas, fixed IP attachment options, network namespace modes other than no-network, and IPAM controls beyond one IPv4/IPv6 subnet.
- [A2: Apple Gap, Host Identity And Links](#a2-apple-gap-host-identity-and-links): [`apple/container`][apple-container] gap. Demonstrates hostname, domain name, explicit host entries, and legacy links.
- [A3: Apple Gap, Runtime Controls](#a3-apple-gap-runtime-controls): [`apple/container`][apple-container] gap. Demonstrates namespace controls, privileged/device access, resource controls beyond the supported local limits, and sysctls.
- [A4: Apple Gap, Health, Secrets, And Restart](#a4-apple-gap-health-secrets-and-restart): [`apple/container`][apple-container] gap. Demonstrates healthchecks, healthy/completed dependency gates, service secrets/configs, and restart policies.
- [A5: Apple Gap, Runtime Data Commands](#a5-apple-gap-runtime-data-commands): [`apple/container`][apple-container] gap. Demonstrates process listing, event streams, dynamic host-port allocation, pause/unpause, already-stopped exit-code replay, and copy archive/follow-link controls.
- [A6: Apple Gap, Advanced Build Fields](#a6-apple-gap-advanced-build-fields): [`apple/container`][apple-container] gap. Demonstrates additional contexts, unsupported secret forms and metadata, SSH forwarding, and provenance/SBOM fields.
- [A7: Apple Gap, Image Commit And Compose Publish](#a7-apple-gap-image-commit-and-compose-publish): [`apple/container`][apple-container] gap. Demonstrates service-container image commit and Compose application OCI artifact publishing.
- [C1: Plugin Gap, Replica Scaling Edge Cases And Deploy](#c1-plugin-gap-replica-scaling-edge-cases-and-deploy): `container-compose` gap. Demonstrates supported scale forms, collision safeguards, and deploy semantics.
- [C3: Plugin Gap, Develop, Providers, Models, And Hooks](#c3-plugin-gap-develop-providers-models-and-hooks): `container-compose` gap. Demonstrates watch/develop, providers, model bindings, and lifecycle hooks.
- [C4: Plugin Gap, Metadata, Storage, And API Socket](#c4-plugin-gap-metadata-storage-and-api-socket): `container-compose` gap. Demonstrates logging options, external inherited mounts, advanced service volume options, API socket, and block I/O.
- [C5: Plugin Gap, Additional CLI Commands](#c5-plugin-gap-additional-cli-commands): `container-compose` gap. Demonstrates default interactive attach behavior that still needs command-level plugin design.
- [O1: Config-Only Metadata](#o1-config-only-metadata): Config-only. Demonstrates extension metadata, top-level models/secrets, and `expose` in normalized output.

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
container compose stats --no-trunc api
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

Expected result: `container compose up` rejects this before creating resources because [`apple/container`][apple-container] needs multi-network attach/connect, per-network aliases/options beyond MAC and MTU, service-name DNS that can return multiple replica addresses, fixed addresses, network namespace modes other than no-network, and IPAM controls beyond one IPv4/IPv6 subnet.

Status path:

- Docker Compose v2: accepts and normalizes these network attachments.
- [`apple/container`][apple-container]: missing multi-network attach/connect, per-network aliases/options beyond MAC and MTU, service-name aliases and multi-record DNS lookup for scaled replicas, fixed addresses, Docker-compatible namespace modes other than no-network, IPAM gateway/range/auxiliary-address controls, custom IPAM drivers, and multiple same-family IPAM subnets.
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

  worker:
    build:
      context: ./worker
    deploy:
      replicas: 2

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

Dockerfile: `worker/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo worker; sleep 30; done"]
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
- [`apple/container`][apple-container]: missing dynamic host-port allocation, process listing, event streaming, pause/unpause, stored exit-code metadata for already-stopped containers, and copy archive/follow-link controls.
- `container-compose`: exposes the command names, resolves explicit published-port lookups from runtime snapshots, supports indexed target lookup for existing Compose-managed service containers, supports `stats --all` by combining direct stats for running containers with stopped-container metadata from project discovery, supports `stats --no-trunc` because the direct renderer already emits full container IDs, supports `wait` and `wait --down-project` for running/stopping service containers, and reports the Apple runtime gap for requests that need unavailable runtime state.

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

Expected result: `container compose up` accepts simple local replica counts for services that can be safely duplicated, including services with explicit host port ranges large enough to allocate one deterministic slice per replica and services with anonymous volumes that can be named per replica. It rejects the `worker.deploy.update_config` field in this example because update orchestration needs Compose deploy semantics beyond local replica count and CPU/memory limits. Scaled services reject before side effects when a Compose file would create duplicate runtime names, duplicate fixed published ports, or duplicate fixed MAC addresses.

Status path:

- Docker Compose v2: accepts and normalizes scaling and deploy metadata.
- [`apple/container`][apple-container]: supports the lifecycle and resource primitives needed for these local scale forms, while scaled service-name DNS is tracked in [A1](#a1-apple-gap-networking).
- `container-compose`: maps standalone `scale`, `up --scale`, `create --scale`, service `scale`, and local `deploy.replicas` to indexed containers; maps large enough published-port ranges to deterministic per-replica host ports; maps anonymous volumes to deterministic per-replica runtime volume names; maps `deploy.resources.limits.cpus` and `deploy.resources.limits.memory` to local runtime limits; can target indexed service containers for `logs`, `attach`, `exec`, `cp`, `export`, and `port`; and rejects scaled `container_name`, too-small published-port ranges, and fixed MAC addresses before creating resources. It still needs broader deploy semantics.

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
    volumes:
      - /scratch
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

### A6: Apple Gap, Advanced Build Fields

Expected result: `container compose build` rejects this before running `container build` because `apple/container build` does not expose Docker Compose compatible BuildKit primitives for the advanced build fields and secret metadata in this example.

Status path:

- Docker Compose v2: accepts and normalizes these build fields.
- [`apple/container`][apple-container]: missing BuildKit-compatible primitives for additional contexts, build network/host/privilege settings, SSH forwarding, advanced secret metadata, and provenance/SBOM attestations.
- `container-compose`: recognizes the normalized fields and rejects them before invoking `container build`.

```yaml
# compose.yaml
name: apple-build-gap-demo

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

### A7: Apple Gap, Image Commit And Compose Publish

Expected result: `container compose commit` and `container compose publish` are recognized command names, then reject with Apple/runtime-gap messages. Existing Apple/container image primitives such as image save, tag, push, and container export are useful adjacent operations, but they do not create a new image from a service container's changed filesystem or package a Compose application as an OCI artifact that can be consumed with `oci://`.

Status path:

- Docker Compose v2: supports service-container image commits and Compose application publishing.
- [`apple/container`][apple-container]: missing a container commit image-snapshot primitive and Compose application OCI artifact publish/consume primitives.
- `container-compose`: exposes the command names and reports the Apple runtime boundary precisely.

```yaml
# compose.yaml
name: apple-image-artifact-gap-demo

services:
  api:
    build:
      context: ./api
    image: example/api:dev

  worker:
    build:
      context: ./worker
    image: example/worker:dev
```

Compare the missing command behavior:

```sh
container compose commit api example/api:snapshot
container compose publish example/app:latest
docker compose -f oci://example/app:latest config
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

### C3: Plugin Gap, Develop, Providers, Models, And Hooks

Expected result: `container compose config` preserves the `develop.watch` trigger metadata, and `container compose --dry-run watch api` validates service selection and trigger shape before printing the planned watch settings/actions. Live `container compose watch api` still reports that file watching and develop actions are not implemented yet. `container compose up` rejects this because watch/develop, provider/model wiring, and lifecycle hooks need plugin orchestration.

Status path:

- Docker Compose v2: accepts and normalizes develop, provider, model, and hook fields.
- [`apple/container`][apple-container]: not known to be the first blocker for this example.
- `container-compose`: preserves normalized `develop.watch` trigger metadata, validates `watch` command selections, and emits a dry-run watch plan. It still needs live file watching, sync/rebuild/restart action execution, service providers, model bindings, and hook execution.

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
container compose --dry-run watch --no-up --no-prune --quiet api
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

Expected result: output-only `container compose attach --no-stdin --sig-proxy=false` works through the runtime log stream. Default Docker Compose attach semantics still reject because the plugin needs an interactive attach design for stdin forwarding, signal proxying, and detach-key behavior.

Status path:

- Docker Compose v2: supports default interactive attach behavior.
- [`apple/container`][apple-container]: log streaming is available for output-only attach; deeper runtime attach support may be needed after the plugin design is settled.
- `container-compose`: supports output-only attach and reports the remaining design gap for default interactive attach. `watch` command validation is tracked in [C3](#c3-plugin-gap-develop-providers-models-and-hooks), and `commit`/`publish` runtime gaps are tracked in [A7](#a7-apple-gap-image-commit-and-compose-publish).

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

Compare the supported and missing command behavior:

```sh
container compose attach --no-stdin --sig-proxy=false api
docker compose attach api
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
