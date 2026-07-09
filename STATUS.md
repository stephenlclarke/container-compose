# Status

Last updated: 2026-07-08.

This file is the current-state handoff for `container-compose`. Keep it short. Do not store branch policy or historical evidence here; use [BRANCHES.md](BRANCHES.md), git history, GitHub Actions runs, SonarQube, and the handoff drafts under `docs/upstream/` when old details are needed.

## Current State

`main` is the current releasable integration branch and source of stable semantic tags. Land validated slices on `main`, then use `make release VERSION_SELECTOR=--+` to produce the next stable release and Homebrew tap update. Keep branch policy, `CONTAINER_STACK_RELEASE.sh`, and Homebrew details in [BRANCHES.md](BRANCHES.md); this file should only record the current handoff state.

## Current Integration Assumption

`container-compose` is supported as part of the fork-backed Stephen runtime bundle. Keep each package lane pinned to the matching `stephenlclarke/container`, `stephenlclarke/containerization`, and `container-builder-shim` surfaces until equivalent Apple upstream APIs are accepted and the plugin has been updated to those upstream surfaces.

Full build support, including BuildKit checks, SSH forwarding, additional contexts, provenance/SBOM attestations, and Dockerfile frontend options, assumes that bundled Stephen runtime path.

The main drift risks are logs, events, restart policy, health, exit/completion metadata, networking identity, IPAM/DNS, process listing, dynamic ports, copy/archive behavior, build inputs, mounts, secrets/configs, blkio, sysctls, and runtime API shape changes.

Current reviewed package pins:

- `stephenlclarke/container`: `97a05cb46aa8aa15acb69fe558a18c88156533a7`
- `stephenlclarke/containerization`: `45e2131718b90a44a2d64e773f42b90d61059394`
- `ghcr.io/stephenlclarke/container-builder-shim/builder`: `0.13.6`

## Latest Local Validation

The latest local validation for this compatibility refresh passed with `make ci`, `make docker-compose-parity`, `npx --yes markdownlint-cli README.md STATUS.md docs/parity/compose-cli-surface.md docs/upstream/container-compose/ISSUE-compose-parallel-image-operations.md docs/upstream/container-compose/PR-compose-parallel-image-operations.md`, and `git diff --check`.

Current full coverage proof:

- Swift: 842 Compose tests at 89.32% line coverage.
- Go normalizer: 92.56% line coverage.

## Recent Functional State

- Progress feedback: project loading, variable loading, image build, image pull, direct runtime create/start/run, foreground interactive `run`, and attached `exec` emit visible stderr progress before slow or terminal-taking operations can look hung.
- Build and image behavior: Compose `dockerfile` paths resolve relative to build context, local build contexts are handed to `container build` as standardized absolute project paths to avoid the relative-context runtime gap tracked by [apple/container#1899](https://github.com/apple/container/issues/1899), list-form entrypoints map correctly to Apple `--entrypoint`, `compose build --print` renders deterministic Buildx bake JSON without build/push side effects, `compose build --check` runs BuildKit lint through the fork-backed build path, `build --print --check` renders `call: "lint"` without outputs, `build --builder default` and named `build --builder NAME` selections flow through to the fork-backed `container build` backend, provenance/SBOM attestations and `build.ssh` / `--ssh` flow through the same path, file/env-backed `build.secrets` map to BuildKit secret IDs while Docker Compose-compatible `uid`/`gid`/`mode` metadata is accepted and ignored for build execution, `additional_contexts` supports paths, remote contexts, and service contexts with build-order expansion, `build.entitlements`, `extra_hosts`, `isolation`, `network`, `privileged`, `shm_size`, and `ulimits` map to the BuildKit-compatible build model, explicit false attestation forms remain no-op opt-outs, and explicit root `--parallel` values cap repeated `pull` and `push` image work.
- Core command support: `compose run`, `run --no-deps`, `down [SERVICES]`, `create`, `config`, `ps [SERVICE...]`, `watch`, `up --watch`, `up --menu`, command-level `up --menu --watch`, `up --attach`, `up --attach-dependencies`, exit-control `up` flags, `exec --privileged`, and service, lifecycle, or watch `privileged: true` are covered by focused tests or runtime smoke.
- Deploy metadata: Docker Compose-compatible `deploy.endpoint_mode` and CPU/memory Deploy reservations are accepted as local metadata, while Swarm-only deploy modes, start-first update ordering, pids/device/generic reservations, and unmapped Deploy resource limits remain blocked by Apple runtime semantics and fail before side effects.
- Mount behavior: bind mounts preserve Docker Compose `bind.create_host_path` policy; missing sources are rejected before side effects when the policy is false, while default or true bind sources are created as host directories before Apple runtime create/run handoff. Bind `propagation` values are passed as runtime mount options. Service long-form `volume.labels` are preserved in config; anonymous volume labels are applied to deterministic runtime volumes before create/run handoff, and named service mount labels remain metadata because Docker Compose keeps named resource labels under top-level `volumes.<name>.labels`. Runtime-inherited `volumes_from` mounts from external containers pass through without host-path preparation.
- Namespace modes: `network_mode: none` and `pid: host` are accepted for service containers and one-off `run`. `network_mode: host` maps to the Stephen fork-backed `container --network host` runtime path without attaching the Compose project network. Service/container namespace-sharing forms remain blocked pending a Docker-compatible runtime namespace-join primitive.
- Network resources: top-level `networks.<name>.driver_opts` are preserved in normalized config and passed to Apple network creation through plugin-specific options. One IPv4 and one IPv6 IPAM subnet are mapped to Apple network creation. Driver-specific `networks.<name>.ipam.options` and other unmapped IPAM fields are rejected before side effects because Apple network creation does not expose a matching IPAM option surface. Service network attachment `driver_opts` support remains limited to Docker-compatible MTU keys because Apple attachment options expose MTU but not arbitrary endpoint driver options.
- Device controls: service `device_cgroup_rules` is accepted for service containers and one-off `run`, validated before side effects, and mapped to the Stephen fork-backed `container --device-cgroup-rule` runtime path. Service `devices` is accepted for supported Linux VM device paths and mapped to the Stephen fork-backed `container --device` runtime path. GPU requests and arbitrary macOS hardware passthrough remain blocked pending Docker-compatible passthrough primitives.
- Cleanup behavior: `down` and `rm` treat already-missing containers as absent, resource deletion treats missing networks and volumes as absent, and `rm` now follows Docker Compose stopped-container semantics: running containers are skipped unless `--stop` is requested and empty cleanup reports `No stopped containers`.
- Runtime dependency preflight: runtime-backed Compose commands check that the active `container` install reports `stephenlclarke/container` plus `stephenlclarke/containerization` provenance before doing work; Apple stock or missing components fail with Homebrew formula guidance and the GitHub install URL.
- Attach and foreground output: `attach --no-stdin` follows selected service logs and supports default signal proxying; `up --no-color`, `up --no-log-prefix`, and `up --timestamps` are supported through the raw foreground or structured log paths.
- Packaging and quality: CodeQL gates the release-built Go normalizer path and the current fork-backed Swift dependency graph, and all Go package outputs are release-built with `CGO_ENABLED=0`, `-trimpath`, and stripped linker flags.
- Packaging: `container` still publishes the moving `homebrew-main` runtime package. `container-compose` follows the latest stable semantic release and records the published runtime commit in package metadata so `brew upgrade` keeps the installed stack aligned and runtime/plugin mismatches fail fast.

## Current Limits

- Interactive attach with stdin reattach remains blocked until Apple exposes an interactive attach primitive.
- `up --menu` is supported for attached terminal log-follow sessions, including detach, watch toggle, command-level `--watch` start, graceful stop, force stop shortcuts, and exit-control options. Docker Desktop-only shortcuts are intentionally absent.
- Build support assumes the matching `stephenlclarke/container` build backend and the current builder image. Build secrets that cannot be materialized as file/env-backed secret IDs remain unsupported.
- Root `--parallel` support currently applies to repeated `pull` and `push` image operations. Dry-run output, build planning, create/start ordering, dependency traversal, and runtime lifecycle reconciliation remain deterministic and ordered.
- `.dockerignore` negation patterns that re-include descendants under an excluded parent remain a builder-shim build-context gap tracked by [apple/container#1800](https://github.com/apple/container/issues/1800) and [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87); the plugin preserves Compose build inputs and delegates context transfer to the fork-backed build backend, so Docker-compatible filtering depends on the builder-shim fix.
- Implicit or relative build contexts from symlinked temporary directories, such as `/var` resolving through `/private/var`, remain a runtime build-context gap tracked by [apple/container#1899](https://github.com/apple/container/issues/1899); the plugin already resolves Compose service build contexts to project-absolute paths where it owns the handoff, but runtime-default `container build` behavior still depends on the upstream canonicalization fix.
- Nested bind mounts that overlay a subdirectory within an earlier bind mount remain an Apple runtime gap tracked by [apple/container#1890](https://github.com/apple/container/issues/1890); the plugin can preserve and order the mount entries, but Docker-compatible mount-over-mount behavior depends on runtime support.
- Namespace sharing via `network_mode: service:NAME`, `network_mode: container:NAME`, `pid: service:NAME`, and `pid: container:NAME` remains blocked until the runtime exposes Docker-compatible namespace-joining primitives.
- Driver-specific `networks.<name>.ipam.options` remain blocked until the runtime exposes a Docker-compatible IPAM option surface.
- Arbitrary service network attachment `driver_opts` remain blocked until the runtime exposes a Docker-compatible endpoint option surface; Docker-compatible MTU options are already mapped.
- Service `devices` currently resolves only the runtime-supported Linux VM device table, including `/dev/null`, `/dev/zero`, `/dev/full`, `/dev/random`, `/dev/urandom`, `/dev/tty`, `/dev/console`, and `/dev/ptmx`. Source paths and explicit target paths must be absolute. Docker Compose can pass relative target strings through the Engine API in ambiguous short-form cases such as `/dev/null:rw`; the fork-backed CLI bridge rejects those forms so `rw` is not silently treated as Docker CLI permissions.
- `gpus`, arbitrary macOS hardware passthrough, and Deploy device reservations remain blocked until the runtime exposes Docker-compatible GPU, host-device passthrough, and scheduler/device-resource primitives.
- `tty: true` without `stdin_open: true` preserves Docker Compose's independent terminal flags, but Apple `container --tty` without `--interactive` has open signal/termination behavior tracked by [apple/container#1876](https://github.com/apple/container/issues/1876); keep watching the runtime fix before adding a plugin-side workaround that could change stdin semantics.

## Upstream Compatibility

Released Apple `container` compatibility is not a supported-lane functionality gap. The Homebrew preview lane requires the Stephen fork-backed runtime stack and preflights for it before runtime-backed Compose commands run. Stock Apple compatibility remains an upstream/release-channel blocker until equivalent runtime primitives are accepted by Apple and this plugin is updated to consume those upstream APIs.

## Open Blockers

- The immutable `ghcr.io/stephenlclarke/container-builder-shim/builder:0.13.6` GHCR image has been published and manifest-verified for linux/arm64.
- SonarCloud quality gate is currently OK on `main` with 0 unresolved issues after `SONAR_QUALITYGATE_WAIT=true make sonar-scan` and a SonarCloud issues API check for branch `main`.

## Open Follow-ups

- Continue live runtime smoke around progress rendering when touching slow paths. If a local `container compose` run or build appears to hang before any screen output, treat that as a progress regression: reproduce the silent phase, add a focused first-frame test, and emit a Docker Compose-style spinner/status row before the blocking operation begins.

## Next Step

Continue the strict gap scan with `gpus`, arbitrary macOS hardware passthrough, generic service endpoint `driver_opts`, and Deploy device reservations treated as runtime-primitive blockers unless matching Apple-shaped fork primitives are added.
