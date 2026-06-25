<!-- markdownlint-disable MD013 -->

# Apple-to-Compose Migration Review

Snapshot date: 2026-06-23.

This review reclassifies the local `apple/containerization` and `apple/container` fork work after JLogan's maintainer comment as `@jglogan` on [`apple/container#1769`](https://github.com/apple/container/pull/1769#issuecomment-4780439328). The important direction is that Apple does not appear to be aiming for full Docker-compatible command coverage outside core resource management, with `build` called out as the notable exception. `container-compose` should therefore own Docker Compose compatibility behavior and adapt to Apple-native primitives rather than pushing Docker-shaped parser and presentation surfaces upstream.

## 2026-06-23 Refresh Result

The `container` and `container-compose` remotes were fetched before this audit. Every checked-out `container` worktree listed below was clean and exactly aligned with its tracked fork branch (`rev-list --left-right --count @{upstream}...HEAD` returned `0 0`), so there was no hidden uncommitted or unpublished Apple source work to rescue before moving functionality.

Update from 2026-06-24: the earlier unsquashed log review worktree and its tracked fork branch were removed after the equivalent work was preserved in the current squashed `develop` history and handoff notes.

The concrete functionality moved back into `container-compose` in the first pass is Docker/Compose time parsing. `ComposeTimeParser` now owns Docker-shaped log/event timestamp strings and Compose/Go-style duration strings before the runtime boundary, and the Compose tests cover RFC 3339/RFC 3339 nano, date-only timestamps, local Docker timestamp layouts, Unix timestamps with fractional seconds, fractional relative durations, malformed Unix timestamps, and malformed relative durations. That leaves `apple/container#1765` as optional Apple CLI parser work, not a dependency for this plugin.

A second pass moved create-time Docker/Compose projection into this repository without changing live execution yet. `container-compose` now builds typed values for local logging policy, healthcheck inheritance and overrides, restart policies, host entries, sysctls, and block I/O resource data. A 2026-06-24 follow-up added the first typed service-create plan adapter and wired the existing `container run/create` command-vector path through that plan for logging policy projection. The existing command-vector path remains the live execution path until image/kernel resolution and direct `ContainerClient.create(configuration:options:)` execution are wired, but the Compose-shaped parsing and validation no longer needs to live in Apple's CLI parser layer.

No other local `container` source changes can be moved directly without replacing the create/run execution path. The remaining broad-branch deltas are either non-emulatable lower runtime behavior, typed Apple client/resource primitives, or runtime schedulers/observers. The next code-heavy migration in this repository is resolving the image description, kernel, init image, and runtime data inputs needed to turn the service-create plan into direct `ContainerConfiguration` and `ContainerCreateOptions` calls, while keeping Docker-shaped command vectors as dry-run presentation.

## Local Audit Scope

| Checkout | Branch or worktree | Status | Apple-bound contents found |
| --- | --- | --- | --- |
| `/Users/sclarke/github/containerization` | `integration/blkio-runtime` | Staged deletions only, tracking origin `0 0`: six handoff docs removed from the fork after being moved here | Committed lower-runtime block I/O resources, pause controls, copy symlink/archive options, and process identifiers |
| `/Users/sclarke/github/container` | `develop` | Clean, tracking fork | Broad squashed integration branch: logs, local log policy/rotation, exit metadata, health checks, restart policies, image healthcheck metadata, identity/network primitives, blkio, sysctls, pause, copy, process identifiers, events |
| `/Users/sclarke/github/container-logs-tail-until` | `logs-tail-until-delta` | Clean, tracking fork `0 0` | Narrow log retrieval options slice |
| `/Users/sclarke/github/container-logs-unix-timestamps` | `logs-unix-timestamp-filters` | Clean, tracking fork `0 0` | Narrow log Unix timestamp parser slice; Docker string parsing is now mirrored and owned by `ComposeTimeParser` |
| `/Users/sclarke/github/worktrees/container-restart-policy-create-options` | `restart-policy-create-options` | Clean, tracking fork `0 0` | Narrow create-time restart policy slice |
| `/Users/sclarke/github/worktrees/container-restart-policy-runtime` | `restart-policy-runtime` | Clean, tracking fork `0 0` | Narrow runtime restart scheduler slice |
| `/Users/sclarke/github/worktrees/container-restart-policy-timing` | `restart-policy-timing` | Clean, tracking fork `0 0` | Narrow restart delay/window slice |
| `/Users/sclarke/github/container-compose` | `develop` | Dirty only with unrelated untracked local files after later branch cleanup | Compose mappings for logs, health/dependencies, restart, configs/secrets, network identity, blkio, sysctls, pause, copy, top, and events |

## Live Authored Apple PRs

Checked with `gh` on 2026-06-23.

| PR | State | Migration read |
| --- | --- | --- |
| [`apple/container#1758`](https://github.com/apple/container/pull/1758), `fix(logs): resolve SwiftLog handler deprecation warnings...` | Open | Unrelated to Docker/Compose compatibility. Keep as a normal upstream hygiene PR. |
| [`apple/container#1764`](https://github.com/apple/container/pull/1764), `feat(logs): add tail and until retrieval filters` | Open | Still useful if it is framed as typed log retrieval capability. Remove or soften any Docker-compatible parser/presentation wording. Compose should pass typed options after local parsing. |
| [`apple/container#1765`](https://github.com/apple/container/pull/1765), `feat(logs): accept Docker-compatible timestamp filters` | Open | Reconsider before investing further. The Docker-compatible timestamp surface belongs in `container-compose`; Apple should only need typed dates or an Apple-native time option if maintainers want one for `container logs`. |

The `apple/container#1769` discussion also has the user's follow-up asking whether downstream tool developers should build against Apple-native `container system ...` surfaces rather than Docker-shaped compatibility commands. Until maintainers answer otherwise, this migration review assumes yes.

## New Boundary

The durable boundary should be:

- `apple/containerization`: lower runtime capabilities that cannot be emulated correctly in the plugin, such as cgroup resources, pausing the sandbox process, copy protocol metadata, and process identifiers.
- `apple/container`: Apple-native typed API/resource primitives and runtime mechanics, such as `ContainerConfiguration` fields, `ContainerCreateOptions`, event streams, log record streams, health status, exit metadata, and restart scheduling.
- `container-compose`: all Docker Compose parsing, normalization, policy decisions, service selection, fan-out, labels, output formats, compatibility aliases, dry-run command rendering, and Docker-shaped strings.

The practical implementation move is to stop making `container-compose` depend on Docker-shaped `container run/create/logs/events/cp/top` CLI flags wherever a typed Swift API can carry the same information. The plugin can still render a familiar dry-run preview, but actual execution should prefer typed adapters such as `ContainerClient.create(configuration:options:)`, log/event options, lifecycle managers, copy options, and image metadata APIs.

## Functionality Classification

| Area | Local Apple work | Best home after the direction change | Migration action |
| --- | --- | --- | --- |
| Docker/Compose time strings | `ContainerLogTimestampParser` and Apple CLI parsing in the log/event branches | `container-compose` | Moved into `ComposeTimeParser`; Compose tests now cover the Apple parser cases plus malformed Unix and relative-duration rejections, and only typed `Date` values cross the Apple boundary |
| Log retrieval options | `ContainerLogOptions`, API-service filters, static/follow retrieval, structured records | Mixed: typed retrieval primitives in `apple/container`, Compose log policy in `container-compose` | Keep typed `tail`, `since`, `until`, `timestamps`, stream identity, and structured records as Apple primitives; keep service fan-out, prefix/color/timestamp rendering, replica selection, and Docker string parsing in Compose |
| Local log driver/policy | Apple branch models `json-file`, `local`, `none`, `max-size`, `max-file`, writer rotation, retained replay | Runtime writer mechanics in `apple/container`; Docker driver aliases and Compose validation in `container-compose` | Reframe Apple PRs around a generic local capture/retention policy instead of Docker logging-driver compatibility; Compose should translate `logging.driver/options` to typed policy |
| Log rotation replay/follow | Apple branch owns raw and structured rotated file replay/follow | `apple/container` primitive | Keep upstream only as storage-cursor/retention mechanics; Compose should not poll or merge rotated files itself, but should own all output formatting |
| Event stream | Apple branch adds lifecycle event stream and event options | Mixed | Keep generic event stream and typed `ContainerEventOptions` in Apple; keep project/service filtering, one-off suppression, private label stripping, JSON/text shape, time-string parsing, and dry-run presentation in Compose |
| `docker info` / system info shape | `apple/container#1769` direction signal, no required local code found in the audit | `container-compose` only if a Compose workflow truly needs Docker-shaped info | Do not submit a Docker-compatible `container info` surface upstream; ask Apple for `container system status` or typed status APIs only when Compose has a concrete need |
| Health status and probes | Apple branch adds `HealthStatus`, `ContainerHealthCheck`, observer, CLI health flags, image healthcheck metadata | Runtime health mechanics in Apple; Compose merge/parse/dependency semantics in Compose | Keep health status, configured probe execution, and image metadata as typed Apple primitives; Compose now has the typed `ContainerHealthCheck` projection for explicit and inherited healthchecks, while live create still uses the command-vector bridge |
| Restart policies | Apple branches add create options, runtime restart tracker, delay/window | Runtime scheduling in Apple; Compose policy mapping in Compose | Keep `ContainerRestartPolicy` and restart scheduler in Apple; Compose now owns Docker `--restart` parsing and Compose deploy precedence and can pass typed `ContainerCreateOptions.restartPolicy` once direct create is wired |
| Exit metadata / completed dependencies | Apple branch stores exit code and timing | `apple/container` primitive | Keep upstream; Compose needs accurate completed-service conditions and job-mode waits after the Compose process has moved on |
| Image healthcheck metadata | Apple branch exposes Dockerfile `HEALTHCHECK` metadata | `apple/container` typed image metadata primitive | Keep upstream as image inspection data; Compose owns inheritance, timing-only overrides, cache policy, and diagnostics |
| Hostname and domainname | Apple branch adds `ContainerConfiguration.hostname/domainname` and CLI flags | Typed fields in Apple; Compose validation in Compose | Keep typed config fields if not already upstream; Compose owns RFC1123 validation and field handling, and should avoid needing Docker-compatible Apple CLI flags by using typed create APIs |
| Static host entries / `host-gateway` | Apple branch models `/etc/hosts` entries and gateway resolution | Runtime pre-start host file generation in Apple; Compose syntax in Compose | Keep `ContainerConfiguration.HostEntry` and host-gateway resolution upstream; Compose now owns `extra_hosts`, `host.docker.internal` policy, `host:ip` / `host=ip` parsing, and service-specific errors |
| Network aliases / links | Apple branch adds attachment aliases | Typed network attachment aliases in Apple; Compose topology policy in Compose | Keep only network-scoped alias primitive upstream; Compose owns single-network restrictions, `links`, default-network behavior, and selected alias mapping |
| Block I/O | `containerization` adds `LinuxBlockIO`; `container` adds create/runtime bridge | Lower runtime and typed resource config in Apple repos; Compose field conversion in Compose | Keep cgroup plumbing and typed resource data upstream; Compose now owns `blkio_config` parsing, validation, and conversion to typed OCI data instead of requiring Docker-shaped `--blkio` flags long-term |
| Sysctls | Apple branch adds create flags/config | Typed `ContainerConfiguration.sysctls` in Apple; Compose parsing in Compose | Keep typed sysctl configuration upstream; Compose now owns Compose map/list normalization and diagnostics |
| Pause/unpause | `containerization` and `container` add pause controls | Apple lifecycle primitive plus Compose command mapping | Keep pause/resume primitive upstream; Compose owns service selection, all-services behavior, and one-off policy |
| Copy follow-link/archive | `containerization` and `container` add follow symlink and preserve ownership options | Lower copy protocol and typed copy options in Apple; Compose endpoint mapping in Compose | Keep runtime copy semantics upstream; Compose owns `SERVICE:/path` resolution, `--all`, service-to-service staging, and compatibility diagnostics |
| Process identifiers / `top` | `containerization` and `container` expose process identifiers | Apple primitive, Compose presentation | Keep typed process listing upstream; Compose owns service selection and Docker Compose-compatible `top` table rendering |
| Configs/secrets | Compose branch materializes config/secret files and grant modes | `container-compose` | Keep entirely in Compose while using existing bind mounts; no Apple PR needed unless a future native secret primitive appears |
| Deploy job modes | Compose branch maps job-style behavior | Mostly `container-compose`, with exit metadata primitive in Apple | Keep job-mode policy in Compose; retain only exit metadata and wait primitives upstream |
| Dry-run output | Compose previously rendered fork-only `container logs/stats/top/pause/unpause/kill/wait/cp/export/events` commands for direct API paths | `container-compose` | Treat dry-run text as a plugin presentation layer, not proof that Apple must expose every Docker-shaped CLI flag; direct-manager paths now render `compose-runtime ...` markers, while real `container run/create/...` command-vector paths remain unchanged |

## Recommended Migration Order

1. Keep `ComposeTimeParser` as the Docker-shaped timestamp/duration boundary and treat `apple/container#1765` as optional Apple CLI convenience, not a plugin dependency.
2. Keep the typed service-create plan adapter in `container-compose` as the shared projection point for logging, healthcheck, restart, hostname/domainname, host entry, sysctl, blkio, and metadata labels. The command-vector path should continue to consume the same plan while direct create is being wired.
3. Resolve image description, kernel, init image, runtime data, mount, network, DNS, port, process, and resource inputs so live create can call `ContainerClient.create(configuration:options:)` instead of depending on Docker-shaped `container run/create` flags.
4. Refresh Apple PR drafts so parser/CLI flag wording becomes typed API/resource wording. Any Docker-shaped flag names should be described as current fork implementation details, not the upstream ask.
5. Keep Apple PRs only for irreducible runtime primitives: lower-runtime cgroups/copy/pause/process IDs, runtime log/event streams, health observation, restart scheduling, exit metadata, image metadata, and network/DNS primitives.
6. Reclassify `container-compose` PR drafts that already contain the compatibility logic as the primary user-facing work. They should not wait for Apple to accept Docker-compatible command names if a typed primitive can be used instead.

## Local Cleanup Notes

- The only dirty state found inside the Apple checkouts was staged deletion of handoff docs in `/Users/sclarke/github/containerization`. That matches the repo policy that upstream drafts live in `container-compose`.
- No uncommitted Apple source changes were found in `/Users/sclarke/github/container` or its checked-out worktrees.
- The broad Compose-side migration work has been folded into `container-compose` `develop`. The next code-heavy step is not another Apple PR; it is finishing direct service creation from the typed service-create plan in this repo so Docker-shaped Apple CLI flags stop being the plugin's runtime dependency.
- The 2026-06-23 documentation cleanup removed parser-only Apple drafts for healthcheck CLI flags, sysctl CLI flags, local logging driver/options, the stale pre-JLogan submission order, and duplicate event drafts under `docs/upstream/apple-container/`. The canonical event slab now lives under `docs/upstream/events/`, and the remaining Apple drafts are framed around typed primitives or native resource-management behavior. Compose-facing drafts may still mention current `container run/create` command-vector output, but only as a temporary bridge while typed service creation is wired in this repository.
