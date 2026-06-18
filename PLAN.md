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

| Task | Added | Started | Completed | Notes |
| --- | --- | --- | --- | --- |
| Direct API adapter foundation | 2026-06-17 16:12:21 BST | 2026-06-17 16:12:21 BST | 2026-06-17 18:48:12 BST | Backfilled from commits `c4cabbb` through `ecec616`; moved file operations, kill, resources, lifecycle, discovery, logs, stats, images, start, exec, and copy paths toward direct Apple/container APIs. |
| Runtime docs reference | 2026-06-17 15:00:34 BST | 2026-06-17 15:00:34 BST | 2026-06-17 15:00:34 BST | Added Apple/container API documentation references in `DESIGN.md`. |
| Compact CLI option normalization | 2026-06-17 14:09:37 BST | 2026-06-17 14:09:37 BST | 2026-06-17 14:30:13 BST | Backfilled from commits `e730f76` through `da680fa`; aligned short/compact Docker Compose CLI forms. |
| Service labels, direct exec, and generated type design notes | 2026-06-17 18:26:58 BST | 2026-06-17 18:26:58 BST | 2026-06-17 19:39:13 BST | Backfilled from direct exec, label file, deploy resource limit, and design-decision commits. |
| Build feature expansion | 2026-06-17 20:26:51 BST | 2026-06-17 20:26:51 BST | 2026-06-18 08:35:36 BST | Added supported build tags, pull, labels, platforms, cache hints, file/env secrets, inline Dockerfiles, build command options, and service build pull policy. |
| Network and port feature expansion | 2026-06-17 19:57:49 BST | 2026-06-17 19:57:49 BST | 2026-06-18 07:26:56 BST | Added single-network MAC addresses, MTU driver option, no-network mode, internal IPAM subnets, dynamic port rejection, runtime port lookup, and scaled explicit port ranges. |
| Storage feature expansion | 2026-06-18 08:09:21 BST | 2026-06-18 08:09:21 BST | 2026-06-18 09:04:41 BST | Added tmpfs options, volume driver options, and same-project service volume inheritance. |
| Lifecycle and `up` option expansion | 2026-06-18 04:41:20 BST | 2026-06-18 04:41:20 BST | 2026-06-18 09:35:51 BST | Added `up --no-start`, `--no-build`, `--quiet-build`, `--quiet-pull`, `--always-recreate-deps`, `--timeout`, scaling, `wait`, and `wait --down-project`. |
| Interaction command expansion | 2026-06-18 05:55:46 BST | 2026-06-18 05:55:46 BST | 2026-06-18 06:12:08 BST | Added indexed attach/log targets and accepted harmless log display flags. |

## Active Documentation Work

| Task | Added | Started | Completed | Notes |
| --- | --- | --- | --- | --- |
| Add backlog tracking to `PLAN.md` | 2026-06-18 09:36:35 BST | 2026-06-18 09:36:35 BST | 2026-06-18 09:39:04 BST | Include plugin backlog and Apple/container upstream PR backlog. |
| Reformat `BUILD.md` runtime boundary | 2026-06-18 09:36:35 BST | 2026-06-18 09:36:35 BST | 2026-06-18 09:39:04 BST | Split the dense runtime-boundary paragraph into readable responsibilities and adapter tables. |
| Update `DESIGN.md` direct API discussion | 2026-06-18 09:36:35 BST | 2026-06-18 09:36:35 BST | 2026-06-18 09:39:04 BST | Explain that direct Apple/container APIs are preferred wherever available and how that works with compose-go normalization. |

## container-compose Backlog

These tasks are valid Docker Compose v2 surfaces where Apple/container is not
known to be the first blocker. The fix belongs in this repository unless deeper
Apple/container API work is discovered during implementation.

| Task | Added | Started | Completed | Notes |
| --- | --- | --- | --- | --- |
| Default `attach` stdin and signal proxy behavior | 2026-06-18 09:36:35 BST | not started | not completed | Current support is output-only `attach --no-stdin --sig-proxy=false`; full support needs an interactive attach design. |
| `watch` and develop workflows | 2026-06-18 09:36:35 BST | not started | not completed | Needs file watching, sync/rebuild/restart policy, and clear interaction with Compose `develop`. |
| `commit` command | 2026-06-18 09:36:35 BST | not started | not completed | Design service-container target resolution and image naming/output compatibility. |
| `publish` command | 2026-06-18 09:36:35 BST | not started | not completed | Design how Compose project/service image publishing maps to Apple/container image APIs. |
| Replica scaling edge cases | 2026-06-18 09:36:35 BST | not started | not completed | Covers fixed single host-port conflicts, too-small ranges, fixed MAC addresses, `container_name`, and per-replica anonymous volume naming. |
| Local deploy interpretation | 2026-06-18 09:36:35 BST | not started | not completed | Extend beyond local `deploy.replicas` and CPU/memory limits only where local-development semantics are safe and Docker Compose compatible. |
| Advanced build fields | 2026-06-18 09:36:35 BST | not started | not completed | Covers additional contexts, entitlements, build network/isolation/privileged settings, provenance, SBOM, SSH, advanced secrets, shm size, and build ulimits. |
| Providers, models, and lifecycle hooks | 2026-06-18 09:36:35 BST | not started | not completed | Covers service `provider`, `models`, `post_start`, and `pre_stop`. |
| Logging and storage metadata | 2026-06-18 09:36:35 BST | not started | not completed | Covers logging options, storage options, image-declared inherited mounts, external `volumes_from`, advanced bind/volume options, and image mounts. |
| API socket and block I/O support | 2026-06-18 09:36:35 BST | not started | not completed | Needs a security review before exposing `use_api_socket` and `blkio_config` behavior. |

## Apple/container Upstream Backlog

These tasks are valid Docker Compose v2 surfaces where container-compose has
hit, or is expected to hit, an Apple/container runtime primitive gap. These are
good candidates for later PRs against [`apple/container`](https://github.com/apple/container).
It is probably worth creating a fork of Apple/container before starting this
work so the runtime changes can be staged, tested, and proposed upstream in
small reviewable PRs.

| Task | Added | Started | Completed | Notes |
| --- | --- | --- | --- | --- |
| Fork Apple/container for Compose primitive work | 2026-06-18 09:36:35 BST | not started | not completed | Use the fork to stage small upstream PRs that unblock Compose compatibility. |
| Multi-network attachment and aliases | 2026-06-18 09:36:35 BST | not started | not completed | Compose needs multiple service networks, network aliases, richer per-network options, and attach/connect semantics. |
| Fixed addresses and richer IPAM | 2026-06-18 09:36:35 BST | not started | not completed | Compose needs fixed IPv4/IPv6 addresses, gateways, IP ranges, aux addresses, custom IPAM drivers, and multiple same-family subnets. |
| Host identity and host entries | 2026-06-18 09:36:35 BST | not started | not completed | Compose needs hostname, domainname, extra host entries, and legacy link alias behavior. |
| Namespace and cgroup controls | 2026-06-18 09:36:35 BST | not started | not completed | Compose needs compatible `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, and isolation modes. |
| Expanded resource controls | 2026-06-18 09:36:35 BST | not started | not completed | Compose needs CPU scheduler controls beyond `cpus`, memory/swap/OOM/PID limits beyond current supported local limits, and stats truncation control. |
| User, security, device, GPU, and sysctl controls | 2026-06-18 09:36:35 BST | not started | not completed | Compose needs supplemental groups, security profiles, privileged containers and exec, host devices, GPUs, and per-container sysctls. |
| Health status and dependency gates | 2026-06-18 09:36:35 BST | not started | not completed | Compose needs health status and health-aware dependency waits for `service_healthy`. |
| Container completion metadata | 2026-06-18 09:36:35 BST | not started | not completed | Compose needs stored exit code and completion time so `service_completed_successfully` and already-stopped `wait` replay can work. |
| Service config and secret mounts | 2026-06-18 09:36:35 BST | not started | not completed | Compose needs first-class runtime config/secret mount primitives. |
| Restart policies | 2026-06-18 09:36:35 BST | not started | not completed | Compose needs service restart policy support compatible with local Docker Compose behavior. |
| Dynamic host-port allocation | 2026-06-18 09:36:35 BST | not started | not completed | Compose accepts target-only ports such as `"80"`; Apple/container currently requires explicit host ports. |
| Runtime event stream and process listing | 2026-06-18 09:36:35 BST | not started | not completed | Compose `events` and `top` need corresponding runtime APIs. |
| Pause and unpause | 2026-06-18 09:36:35 BST | not started | not completed | Compose `pause` and `unpause` need container pause primitives. |
| Copy archive and follow-link controls | 2026-06-18 09:36:35 BST | not started | not completed | Compose `cp --archive` and `cp --follow-link` need matching file copy controls. |

## Keeping This File Current

When a task moves:

1. Update the timestamp in this file.
2. Update [COMPATIBILITY.md](COMPATIBILITY.md) if the supported or blocked
   surface changes.
3. Add or update tests for the behavior.
4. Validate locally with the appropriate Makefile target before committing.
