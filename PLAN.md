# container-compose Plan

This file tracks the remaining Compose compatibility work and the upstream
Apple/container work that will be needed for stronger Docker Compose v2
compatibility.

## Timestamp Policy

Timestamps use the local development timezone, Europe/London. Historical
entries that existed before this file was created are backfilled from signed Git
commit timestamps. New tasks should record:

- Added: when the task entered this plan.
- Started: when implementation or design work begins.
- Completed: when the tested commit lands on `develop`.

Use `not started` or `not completed` where the event has not happened yet.

## Development Cycle

- Work happens on `develop`.
- Each issue is fixed as one tested Conventional Commit on `develop`.
- Push `develop` after each completed issue.
- Squash only on `develop` when a single issue needs multiple local commits.
- Batch `develop` to `main`; do not leave it too long before the batch merge.
- Use local Makefile validation first because it is faster than waiting for
  GitHub runners.
- Post to `xyzzy-tools.slack.com#codex` before and after each code slice.
- SonarQube remediation can be batched to `main`, but SonarQube fixes should
  be pushed to `main` after each fix when formal SonarQube validation is the
  active workflow.

## Completed Work

| Task | Added | Started | Completed |
| --- | --- | --- | --- |
| Direct API adapter foundation | 2026-06-17 16:12:21 BST | 2026-06-17 16:12:21 BST | 2026-06-17 18:48:12 BST |
| Notes: Backfilled from commits `c4cabbb` through `ecec616`; moved file operations, kill, resources, lifecycle, discovery, logs, stats, images, start, exec, and copy paths toward direct Apple/container APIs. | | | |
| Runtime docs reference | 2026-06-17 15:00:34 BST | 2026-06-17 15:00:34 BST | 2026-06-17 15:00:34 BST |
| Notes: Added Apple/container API documentation references in `DESIGN.md`. | | | |
| Compact CLI option normalization | 2026-06-17 14:09:37 BST | 2026-06-17 14:09:37 BST | 2026-06-17 14:30:13 BST |
| Notes: Backfilled from commits `e730f76` through `da680fa`; aligned short/compact Docker Compose CLI forms. | | | |
| Service labels, direct exec, and generated type design notes | 2026-06-17 18:26:58 BST | 2026-06-17 18:26:58 BST | 2026-06-17 19:39:13 BST |
| Notes: Backfilled from direct exec, label file, deploy resource limit, and design-decision commits. | | | |
| Build feature expansion | 2026-06-17 20:26:51 BST | 2026-06-17 20:26:51 BST | 2026-06-18 08:35:36 BST |
| Notes: Added supported build tags, pull, labels, platforms, cache hints, file/env secrets, inline Dockerfiles, build command options, and service build pull policy. | | | |
| Network and port feature expansion | 2026-06-17 19:57:49 BST | 2026-06-17 19:57:49 BST | 2026-06-18 07:26:56 BST |
| Notes: Added single-network MAC addresses, MTU driver option, no-network mode, internal IPAM subnets, dynamic port rejection, runtime port lookup, and scaled explicit port ranges. | | | |
| Storage feature expansion | 2026-06-18 08:09:21 BST | 2026-06-18 08:09:21 BST | 2026-06-18 09:04:41 BST |
| Notes: Added tmpfs options, volume driver options, and same-project service volume inheritance. | | | |
| Lifecycle and `up` option expansion | 2026-06-18 04:41:20 BST | 2026-06-18 04:41:20 BST | 2026-06-18 09:35:51 BST |
| Notes: Added `up --no-start`, `--no-build`, `--quiet-build`, `--quiet-pull`, `--always-recreate-deps`, `--timeout`, scaling, `wait`, and `wait --down-project`. | | | |
| Interaction command expansion | 2026-06-18 05:55:46 BST | 2026-06-18 05:55:46 BST | 2026-06-18 06:12:08 BST |
| Notes: Added indexed attach/log targets and accepted harmless log display flags. | | | |
| Develop watch model boundary | 2026-06-18 09:44:11 BST | 2026-06-18 09:44:11 BST | 2026-06-18 09:54:37 BST |
| Notes: Preserved `develop.watch` triggers from compose-go in the Swift model and added command-level `watch` validation. File-watch loops and action execution remain open plugin work. | | | |
| Scaled anonymous service volumes | 2026-06-18 10:07:04 BST | 2026-06-18 10:07:04 BST | 2026-06-18 10:11:26 BST |
| Notes: Mapped anonymous service volumes to deterministic per-replica runtime names when services are scaled and removed those volumes with `down --volumes`. | | | |
| Run capability overrides | 2026-06-18 10:16:25 BST | 2026-06-18 10:16:25 BST | 2026-06-18 10:20:55 BST |
| Notes: Added Docker Compose `run --cap-add` and `run --cap-drop` mapping to Apple/container one-off runtime capability flags. | | | |
| Hawkeye workflow alignment | 2026-06-18 10:23:56 BST | 2026-06-18 10:23:56 BST | 2026-06-18 10:40:06 BST |
| Notes: Added Hawkeye license-header tooling, adopted Apple/container's build-once Swift coverage pattern, cached repo-local tools in CI, documented Apple/container upstream Compose parity gaps, and reformatted planning and compatibility docs for readability. | | | |

## Active Documentation Work

| Task | Added | Started | Completed |
| --- | --- | --- | --- |
| Add backlog tracking to `PLAN.md` | 2026-06-18 09:36:35 BST | 2026-06-18 09:36:35 BST | 2026-06-18 09:39:04 BST |
| Notes: Include plugin backlog and Apple/container upstream PR backlog. | | | |
| Reformat `BUILD.md` runtime boundary | 2026-06-18 09:36:35 BST | 2026-06-18 09:36:35 BST | 2026-06-18 09:39:04 BST |
| Notes: Split the dense runtime-boundary paragraph into readable responsibilities and adapter tables. | | | |
| Update `DESIGN.md` direct API discussion | 2026-06-18 09:36:35 BST | 2026-06-18 09:36:35 BST | 2026-06-18 09:39:04 BST |
| Notes: Explain that direct Apple/container APIs are preferred wherever available and how that works with compose-go normalization. | | | |

## container-compose Backlog

These tasks are valid Docker Compose v2 surfaces where Apple/container is not
known to be the first blocker. The fix belongs in this repository unless deeper
Apple/container API work is discovered during implementation.

| Task | Added | Started | Completed |
| --- | --- | --- | --- |
| Default `attach` stdin and signal proxy behavior | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Current support is output-only `attach --no-stdin --sig-proxy=false`; full support needs an interactive attach design. | | | |
| `watch` and develop workflows | 2026-06-18 09:36:35 BST | 2026-06-18 09:44:11 BST | not completed |
| Notes: Model-boundary support now preserves and validates `develop.watch` triggers. Remaining work needs file watching, sync/rebuild/restart policy, and clear interaction with Compose `develop`. | | | |
| `commit` command | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Design service-container target resolution and image naming/output compatibility. | | | |
| `publish` command | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Design how Compose project/service image publishing maps to Apple/container image APIs. | | | |
| Replica scaling edge cases | 2026-06-18 09:36:35 BST | 2026-06-18 10:07:04 BST | not completed |
| Notes: Per-replica anonymous volume naming is complete. Remaining edge cases cover fixed single host-port conflicts, too-small ranges, fixed MAC addresses, `container_name`, and broader deploy semantics. | | | |
| Local deploy interpretation | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Extend beyond local `deploy.replicas` and CPU/memory limits only where local-development semantics are safe and Docker Compose compatible. | | | |
| Advanced build fields | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Covers additional contexts, entitlements, build network/isolation/privileged settings, provenance, SBOM, SSH, advanced secrets, shm size, and build ulimits. | | | |
| Providers, models, and lifecycle hooks | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Covers service `provider`, `models`, `post_start`, and `pre_stop`. | | | |
| Logging and storage metadata | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Covers logging options, storage options, image-declared inherited mounts, external `volumes_from`, advanced bind/volume options, and image mounts. | | | |
| API socket and block I/O support | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Needs a security review before exposing `use_api_socket` and `blkio_config` behavior. | | | |

## Apple/container Upstream Backlog

These tasks are valid Docker Compose v2 surfaces where container-compose has
hit, or is expected to hit, an Apple/container runtime primitive gap. These are
good candidates for later PRs against [`apple/container`](https://github.com/apple/container).
It is probably worth creating a fork of Apple/container before starting this
work so the runtime changes can be staged, tested, and proposed upstream in
small reviewable PRs.

Recommended upstream workflow:

- Fork [`apple/container`](https://github.com/apple/container) before starting
  runtime work, then create one branch per primitive family.
- Keep each future PR small enough to review independently. The first PR should
  add or expose the Apple/container primitive plus focused runtime tests; the
  matching container-compose mapping should follow in this repository.
- Prefer direct `ContainerClient`, `NetworkClient`, image, volume, process, and
  log APIs so the plugin can stay close to Apple/container's supported design.
- Update Apple/container API documentation with every new public runtime
  primitive so container-compose can link to stable docs instead of inferred
  behavior.

Suggested Apple/container PR batches:

1. Networking parity: multi-network attachment, aliases, fixed addresses, and
   richer IPAM.
2. Build parity: BuildKit-compatible inputs that Docker Compose v2 can express,
   including additional contexts, build networking, SSH, attestations, and
   advanced build secret metadata.
3. Container identity parity: hostname, domain name, host entries, and legacy
   link aliases.
4. Runtime-control parity: namespace modes, cgroups, privileged/device/GPU
   controls, sysctls, and supplemental groups.
5. Mount and storage parity: advanced bind/volume/image mounts, storage
   options, inherited image volumes, and external-container volume inheritance.
6. Health and completion parity: health status, health-aware waits, stored exit
   code, and completion timestamps.
7. Mount and policy parity: first-class config/secret mounts and restart
   policies.
8. Log-data parity: timestamped log records, stream/source metadata, tail and
   since/until filtering, prefix-friendly service/replica attribution, and
   durable closed-container log replay, plus service logging driver/option
   controls.
9. Command-data parity: dynamic host ports, events, process listing,
   pause/unpause, stats truncation control, and copy archive/follow-link
   controls.
10. Runtime API socket parity: a safe Compose-compatible equivalent for
    `use_api_socket` that does not overexpose host control surfaces.

| Task | Added | Started | Completed |
| --- | --- | --- | --- |
| Fork Apple/container for Compose primitive work | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Use the fork to stage small upstream PRs that unblock Compose compatibility. | | | |
| Multi-network attachment and aliases | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose needs multiple service networks, network aliases, richer per-network options, and attach/connect semantics. | | | |
| Fixed addresses and richer IPAM | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose needs fixed IPv4/IPv6 addresses, gateways, IP ranges, aux addresses, custom IPAM drivers, and multiple same-family subnets. | | | |
| BuildKit-compatible build inputs | 2026-06-18 10:34:11 BST | not started | not completed |
| Notes: Compose build parity needs additional contexts, build `extra_hosts`, build network modes, isolation, privileged builds, entitlements, SSH forwarding, advanced secret metadata (`uid`, `gid`, `mode`), build `shm_size`, build `ulimits`, and provenance/SBOM attestations exposed through Apple/container build APIs. Current `container build` supports the common local subset but not the full Compose v2 build surface. | | | |
| Host identity and host entries | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose needs hostname, domainname, extra host entries, and legacy link alias behavior. | | | |
| Namespace and cgroup controls | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose needs compatible `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, and isolation modes. | | | |
| Expanded resource controls | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose needs CPU scheduler controls beyond `cpus`, memory/swap/OOM/PID limits beyond current supported local limits, and stats truncation control. | | | |
| User, security, device, GPU, and sysctl controls | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose needs supplemental groups, security profiles, privileged containers and exec, host devices, GPUs, and per-container sysctls. | | | |
| Advanced mount and storage options | 2026-06-18 10:34:11 BST | not started | not completed |
| Notes: Compose needs bind propagation, SELinux flags, recursive/read-only bind behavior, volume `nocopy`, volume subpaths, image mounts, mount consistency controls, service `storage_opt`, image-declared inherited mounts, and safe external-container `volumes_from` behavior. Current Apple/container mount flags cover the common local subset only. | | | |
| Health status and dependency gates | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose needs health status and health-aware dependency waits for `service_healthy`. | | | |
| Container completion metadata | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose needs stored exit code and completion time so `service_completed_successfully` and already-stopped `wait` replay can work. | | | |
| Service config and secret mounts | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose needs first-class runtime config/secret mount primitives. | | | |
| Restart policies | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose needs service restart policy support compatible with local Docker Compose behavior. | | | |
| Docker Compose log parity | 2026-06-18 10:29:02 BST | not started | not completed |
| Notes: Compose `logs` needs runtime log records with timestamps, stdout/stderr stream metadata, since/until filtering, tailing handled by the runtime, service/replica attribution for prefix output, reliable replay for stopped containers, and service logging driver/option controls such as rotation policy. Current Apple/container APIs expose raw log handles, so container-compose can only approximate unprefixed local log output. | | | |
| Dynamic host-port allocation | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose accepts target-only ports such as `"80"`; Apple/container currently requires explicit host ports. | | | |
| Runtime event stream and process listing | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose `events` and `top` need corresponding runtime APIs. | | | |
| Pause and unpause | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose `pause` and `unpause` need container pause primitives. | | | |
| Copy archive and follow-link controls | 2026-06-18 09:36:35 BST | not started | not completed |
| Notes: Compose `cp --archive` and `cp --follow-link` need matching file copy controls. | | | |
| Runtime API socket exposure | 2026-06-18 10:34:11 BST | not started | not completed |
| Notes: Compose `use_api_socket` needs a safe Docker-compatible or Apple/container-compatible API socket exposure model, including credentials, least-privilege boundaries, and clear behavior when Docker API compatibility is unavailable. | | | |

## Keeping This File Current

When a task moves:

1. Update the timestamp in this file.
2. Update [COMPATIBILITY.md](COMPATIBILITY.md) if the supported or blocked
   surface changes.
3. Add or update tests for the behavior.
4. Validate locally with the appropriate Makefile target before committing.
