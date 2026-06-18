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

Use the status lozenges below where the event has not happened yet.

## Status Lozenges

The lozenges use a traffic-light scheme: green is complete, yellow is active, red is blocked upstream, and gray is not started.

- <span style="background:#E3FCEF;color:#006644;border:1px solid #ABF5D1;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">DONE</span>: tested work has landed on `develop`, or the item needs no further repo work.
- <span style="background:#FFF7D6;color:#7A4D00;border:1px solid #FFE380;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">ACTIVE</span>: work has started and still has repo-owned follow-up.
- <span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span>: Docker Compose v2 compatibility needs [`apple/container`](https://github.com/apple/container) runtime work before this repo can finish the mapping.
- <span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span>: work is tracked but has not started yet.

## Development Cycle

- Work happens on `develop`.
- Each issue is fixed as one tested Conventional Commit on `develop`.
- Push `develop` after each completed issue.
- Squash only on `develop` when a single issue needs multiple local commits.
- Batch `develop` to `main`; do not leave it too long before the batch merge.
- Use local Makefile validation first because it is faster than waiting for
  GitHub runners.
- Post to `xyzzy-tools.slack.com#codex` before and after each code slice.
- When choosing the next implementation target, select one functional topic
  such as replica scaling, advanced build configuration, storage, lifecycle, or
  watch/develop workflows. Work that topic until it is fully implemented or an
  Apple/container blocker is discovered and documented, then move on to the
  next topic.
- SonarQube remediation can be batched to `main`, but SonarQube fixes should
  be pushed to `main` after each fix when formal SonarQube validation is the
  active workflow.

## <span style="background:#E3FCEF;color:#006644;border:1px solid #ABF5D1;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">DONE</span> Completed Work

<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Added</th>
      <th>Started</th>
      <th>Completed</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>Direct API adapter foundation</td>
      <td>2026-06-17 16:12:21 BST</td>
      <td>2026-06-17 16:12:21 BST</td>
      <td>2026-06-17 18:48:12 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Backfilled from commits <code>c4cabbb</code> through <code>ecec616</code>; moved file operations, kill, resources, lifecycle, discovery, logs, stats, images, start, exec, and copy paths toward direct Apple/container APIs.</td>
    </tr>
    <tr>
      <td>Runtime docs reference</td>
      <td>2026-06-17 15:00:34 BST</td>
      <td>2026-06-17 15:00:34 BST</td>
      <td>2026-06-17 15:00:34 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Added Apple/container API documentation references in <code>DESIGN.md</code>.</td>
    </tr>
    <tr>
      <td>Compact CLI option normalization</td>
      <td>2026-06-17 14:09:37 BST</td>
      <td>2026-06-17 14:09:37 BST</td>
      <td>2026-06-17 14:30:13 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Backfilled from commits <code>e730f76</code> through <code>da680fa</code>; aligned short/compact Docker Compose CLI forms.</td>
    </tr>
    <tr>
      <td>Service labels, direct exec, and generated type design notes</td>
      <td>2026-06-17 18:26:58 BST</td>
      <td>2026-06-17 18:26:58 BST</td>
      <td>2026-06-17 19:39:13 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Backfilled from direct exec, label file, deploy resource limit, and design-decision commits.</td>
    </tr>
    <tr>
      <td>Build feature expansion</td>
      <td>2026-06-17 20:26:51 BST</td>
      <td>2026-06-17 20:26:51 BST</td>
      <td>2026-06-18 08:35:36 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Added supported build tags, pull, labels, platforms, cache hints, file/env secrets, inline Dockerfiles, build command options, and service build pull policy.</td>
    </tr>
    <tr>
      <td>Advanced build blocker classification</td>
      <td>2026-06-18 11:37:58 BST</td>
      <td>2026-06-18 11:37:58 BST</td>
      <td>2026-06-18 11:37:58 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Inspected the normalized Compose build fields against <code>container build --help</code> and reclassified advanced BuildKit fields from plugin backlog to Apple/container upstream build parity. The runtime rejection now points to missing Docker Compose compatible Apple/container build primitives.</td>
    </tr>
    <tr>
      <td><code>commit</code> and <code>publish</code> blocker classification</td>
      <td>2026-06-18 11:45:20 BST</td>
      <td>2026-06-18 11:45:20 BST</td>
      <td>2026-06-18 11:45:20 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Inspected Docker Compose v2 command behavior and the available Apple/container image/export APIs, then reclassified <code>compose commit</code> and <code>compose publish</code> from plugin backlog to Apple/container runtime parity. The CLI now reports precise missing runtime primitives for container image snapshots and Compose application OCI artifacts.</td>
    </tr>
    <tr>
      <td>Network and port feature expansion</td>
      <td>2026-06-17 19:57:49 BST</td>
      <td>2026-06-17 19:57:49 BST</td>
      <td>2026-06-18 07:26:56 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Added single-network MAC addresses, MTU driver option, no-network mode, internal IPAM subnets, runtime port lookup, and scaled explicit port ranges. Dynamic host-port allocation was completed later by the dynamic host-port allocation task.</td>
    </tr>
    <tr>
      <td>Storage feature expansion</td>
      <td>2026-06-18 08:09:21 BST</td>
      <td>2026-06-18 08:09:21 BST</td>
      <td>2026-06-18 09:04:41 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Added tmpfs options, volume driver options, and same-project service volume inheritance.</td>
    </tr>
    <tr>
      <td>File-backed service configs and secrets</td>
      <td>2026-06-18 17:49:27 BST</td>
      <td>2026-06-18 17:49:27 BST</td>
      <td>2026-06-18 17:49:27 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Mapped file-backed service <code>configs</code> and <code>secrets</code> to read-only Apple/container bind mounts with Compose-compatible default and long-form targets. External, inline, and environment-backed runtime grants remain Apple/container config/secret store or materialization gaps.</td>
    </tr>
    <tr>
      <td>Logging and storage blocker classification</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 14:20:37 BST</td>
      <td>2026-06-18 14:28:22 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Accepted service <code>volume_driver: local</code> as the supported default local volume driver. Reclassified service logging drivers/options, service <code>storage_opt</code>, non-local service volume drivers, advanced bind/volume mount options, unsupported external block-mount inheritance, API socket exposure, and block I/O controls as Apple/container runtime primitive gaps.</td>
    </tr>
    <tr>
      <td>External <code>volumes_from</code> inheritance</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 14:36:43 BST</td>
      <td>2026-06-18 14:46:45 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Implemented external-container <code>volumes_from</code> inheritance by inspecting referenced Apple/container containers through the direct discovery API, translating supported volume, bind, and tmpfs mounts into runtime arguments, applying <code>ro</code>/<code>rw</code> overrides, and including inherited external mounts in recreate config hashes. Unsupported external block mounts reject before resources are created.</td>
    </tr>
    <tr>
      <td>Lifecycle and <code>up</code> option expansion</td>
      <td>2026-06-18 04:41:20 BST</td>
      <td>2026-06-18 04:41:20 BST</td>
      <td>2026-06-18 09:35:51 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Added <code>up --no-start</code>, <code>--no-build</code>, <code>--quiet-build</code>, <code>--quiet-pull</code>, <code>--always-recreate-deps</code>, <code>--timeout</code>, scaling, <code>wait</code>, and <code>wait --down-project</code>.</td>
    </tr>
    <tr>
      <td>Interaction command expansion</td>
      <td>2026-06-18 05:55:46 BST</td>
      <td>2026-06-18 05:55:46 BST</td>
      <td>2026-06-18 06:12:08 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Added indexed attach/log targets and accepted harmless log display flags.</td>
    </tr>
    <tr>
      <td>Default attach blocker classification</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 14:12:23 BST</td>
      <td>2026-06-18 14:18:53 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Inspected Apple/container init-process attach behavior and reclassified Docker Compose default interactive <code>attach</code> from a plugin design gap to an Apple/container runtime primitive gap. Output-only <code>attach --no-stdin --sig-proxy=false</code> remains supported through runtime log streaming.</td>
    </tr>
    <tr>
      <td>Stats no-trunc display option</td>
      <td>2026-06-18 11:12:17 BST</td>
      <td>2026-06-18 11:12:17 BST</td>
      <td>2026-06-18 11:16:29 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Accept Docker Compose <code>stats --no-trunc</code> because the direct stats renderer already emits full container IDs and does not need an Apple/container CLI truncation flag.</td>
    </tr>
    <tr>
      <td>Develop watch model boundary</td>
      <td>2026-06-18 09:44:11 BST</td>
      <td>2026-06-18 09:44:11 BST</td>
      <td>2026-06-18 09:54:37 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Preserved <code>develop.watch</code> triggers from compose-go in the Swift model and added command-level <code>watch</code> validation. Live action execution was completed later by the watch live action execution task.</td>
    </tr>
    <tr>
      <td>Watch dry-run plan</td>
      <td>2026-06-18 11:22:43 BST</td>
      <td>2026-06-18 11:22:43 BST</td>
      <td>2026-06-18 11:23:47 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Emit a deterministic <code>watch --dry-run</code> plan after validating selected services and <code>develop.watch</code> triggers. Live action execution was completed later by the watch live action execution task.</td>
    </tr>
    <tr>
      <td>Watch live action execution</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 12:43:00 BST</td>
      <td>2026-06-18 13:00:42 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Implemented polling-based <code>compose watch</code> execution for <code>develop.watch</code> actions: initial sync, changed-file sync, deleted-file cleanup, <code>sync+exec</code>, service restart, rebuild, and image pruning. Ordinary <code>up</code> and <code>run</code> now treat <code>develop.watch</code> as harmless metadata.</td>
    </tr>
    <tr>
      <td>Service lifecycle hook execution</td>
      <td>2026-06-18 13:23:28 BST</td>
      <td>2026-06-18 13:23:28 BST</td>
      <td>2026-06-18 13:27:44 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Preserved normalized service <code>post_start</code> and <code>pre_stop</code> hook metadata, validated unsupported hook forms before side effects, and executed supported hooks through direct Apple/container process exec for detached service starts, <code>start</code>, <code>stop</code>, <code>restart</code>, <code>down</code>, service recreation, and replica pruning. Foreground hook ordering now tracks under the Apple/container interactive attach and stop-boundary backlog.</td>
    </tr>
    <tr>
      <td>Detached one-off post-start hook execution</td>
      <td>2026-06-18 13:33:19 BST</td>
      <td>2026-06-18 13:33:19 BST</td>
      <td>2026-06-18 13:33:19 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Executed service <code>post_start</code> hooks after detached one-off <code>compose run</code> containers are created, reusing the generated or explicit one-off container name for direct Apple/container process exec. Foreground <code>run</code> post-start ordering now tracks under the Apple/container interactive attach backlog.</td>
    </tr>
    <tr>
      <td>Detached one-off pre-stop cleanup</td>
      <td>2026-06-18 15:10:06 BST</td>
      <td>2026-06-18 15:10:06 BST</td>
      <td>2026-06-18 15:10:06 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Accepted detached one-off <code>compose run</code> services that declare <code>pre_stop</code> hooks and execute those hooks when container-compose later stops the one-off container through project cleanup, such as <code>up --remove-orphans</code> or <code>down --remove-orphans</code>. Foreground one-off <code>pre_stop</code> remains an Apple/container stop-boundary gap because the foreground init process has already exited before control returns to the plugin.</td>
    </tr>
    <tr>
      <td>Dynamic host-port allocation</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 13:56:09 BST</td>
      <td>2026-06-18 14:06:00 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Allocated ephemeral host ports inside container-compose for target-only, ranged, and host-bound Compose port mappings, then rendered explicit Apple/container <code>--publish</code> bindings for <code>create</code>, <code>up</code>, scaled service replicas, one-off <code>run --service-ports</code>, and manual <code>run --publish</code>. Host-bound IPv4 and bracketed IPv6 mappings are preserved through compose-go normalization. Config hashes remain based on the Compose model rather than the allocated host port.</td>
    </tr>
    <tr>
      <td>Scaled anonymous service volumes</td>
      <td>2026-06-18 10:07:04 BST</td>
      <td>2026-06-18 10:07:04 BST</td>
      <td>2026-06-18 10:11:26 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Mapped anonymous service volumes to deterministic per-replica runtime names when services are scaled and removed those volumes with <code>down --volumes</code>.</td>
    </tr>
    <tr>
      <td>Replica collision safeguards</td>
      <td>2026-06-18 11:52:13 BST</td>
      <td>2026-06-18 11:52:13 BST</td>
      <td>2026-06-18 11:52:13 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Confirmed scaled services reject duplicate runtime names from <code>container_name</code>, too-small fixed published-port ranges, and service-level or per-network fixed MAC addresses before creating resources. Added explicit fixed MAC regression coverage and updated compatibility docs so the remaining plugin-side replica backlog is deploy behavior.</td>
    </tr>
    <tr>
      <td>Replica service discovery blocker classification</td>
      <td>2026-06-18 11:56:51 BST</td>
      <td>2026-06-18 11:56:51 BST</td>
      <td>2026-06-18 11:56:51 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Inspected Apple/container DNS and network services. Runtime DNS lookup returns one attachment per hostname and container creation rejects duplicate attachment hostnames, so Docker Compose service-name DNS for multiple replicas needs Apple/container alias and multi-record lookup primitives before container-compose can map it.</td>
    </tr>
    <tr>
      <td>Deploy replicated mode support</td>
      <td>2026-06-18 12:02:15 BST</td>
      <td>2026-06-18 12:02:15 BST</td>
      <td>2026-06-18 12:02:15 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Explicit <code>deploy.mode: replicated</code> is accepted as the local mode that matches existing replica orchestration. <code>deploy.mode: global</code> was later accepted as Docker Compose local no-op metadata after confirming Docker Compose local convergence uses <code>scale</code> / <code>deploy.replicas</code> and does not read deployment mode.</td>
    </tr>
    <tr>
      <td>Deploy restart policy blocker classification</td>
      <td>2026-06-18 12:05:43 BST</td>
      <td>2026-06-18 12:05:43 BST</td>
      <td>2026-06-18 12:05:43 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Classified <code>deploy.restart_policy</code> with service-level <code>restart</code> as an Apple/container runtime gap. Apple/container exposes lifecycle restart commands but no create/run restart policy primitive.</td>
    </tr>
    <tr>
      <td>Deploy endpoint mode blocker classification</td>
      <td>2026-06-18 12:09:54 BST</td>
      <td>2026-06-18 12:09:54 BST</td>
      <td>2026-06-18 12:09:54 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Classified <code>deploy.endpoint_mode</code> as an Apple/container networking gap. Compose endpoint modes such as <code>vip</code> and <code>dnsrr</code> need service-level discovery semantics that are not exposed by the current runtime.</td>
    </tr>
    <tr>
      <td>Deploy label metadata preservation</td>
      <td>2026-06-18 12:16:03 BST</td>
      <td>2026-06-18 12:16:03 BST</td>
      <td>2026-06-18 12:16:03 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Preserved <code>deploy.labels</code> as service-level metadata without applying it to runtime container labels or including it in recreate config hashes.</td>
    </tr>
    <tr>
      <td>Deploy stop-first update config</td>
      <td>2026-06-18 15:22:32 BST</td>
      <td>2026-06-18 15:22:32 BST</td>
      <td>2026-06-18 15:22:32 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Accepted <code>deploy.update_config.order: stop-first</code> because the local orchestrator already recreates service containers one at a time with a stop-before-start boundary. <code>start-first</code> replacement was later classified as an Apple/container handoff gap, and update metadata such as <code>parallelism</code>, rollback metadata, and placement metadata were later accepted as Docker Compose local no-op metadata.</td>
    </tr>
    <tr>
      <td>Deploy stop-first update delay</td>
      <td>2026-06-18 16:36:37 BST</td>
      <td>2026-06-18 16:36:37 BST</td>
      <td>2026-06-18 16:36:37 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Preserved <code>deploy.update_config.delay</code> from compose-go normalization and applied it between local replica replacements only when the prior replica and current replica both need stop-first recreation. First-time service creation and scale-out do not sleep.</td>
    </tr>
    <tr>
      <td>Deploy start-first update boundary</td>
      <td>2026-06-18 16:48:46 BST</td>
      <td>2026-06-18 16:48:46 BST</td>
      <td>2026-06-18 16:48:46 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Classified <code>deploy.update_config.order: start-first</code> as an Apple/container runtime gap. Docker Compose creates a temporary replacement container, stops/removes the old stable container, then finalizes the replacement identity; Apple/container currently exposes create/stop/delete without a container rename or service hostname/alias handoff primitive.</td>
    </tr>
    <tr>
      <td>Deploy update metadata normalization</td>
      <td>2026-06-18 16:56:12 BST</td>
      <td>2026-06-18 16:56:12 BST</td>
      <td>2026-06-18 16:56:12 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Inspected Docker Compose local orchestration and confirmed <code>deploy.update_config.parallelism</code>, <code>failure_action</code>, <code>monitor</code>, and <code>max_failure_ratio</code> are not applied to local container replacement. These fields are now accepted as Docker Compose local no-op metadata instead of rejected as plugin-owned missing update batching.</td>
    </tr>
    <tr>
      <td>Deploy rollback and placement metadata</td>
      <td>2026-06-18 17:05:01 BST</td>
      <td>2026-06-18 17:05:01 BST</td>
      <td>2026-06-18 17:05:01 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Inspected Docker Compose local orchestration and found no local application of <code>deploy.rollback_config</code> or <code>deploy.placement</code>. The normalizer now accepts rollback and placement sections, including placement constraints, preferences, and <code>max_replicas_per_node</code>, as Docker Compose local no-op metadata.</td>
    </tr>
    <tr>
      <td>Deploy global mode metadata</td>
      <td>2026-06-18 17:12:16 BST</td>
      <td>2026-06-18 17:12:16 BST</td>
      <td>2026-06-18 17:12:16 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Inspected Docker Compose local convergence and compose-go. Local convergence calls <code>GetScale()</code>, which reads <code>scale</code> and <code>deploy.replicas</code>, while no local Compose orchestration path reads <code>deploy.mode</code>. The normalizer now accepts <code>deploy.mode: global</code> as Docker Compose local no-op metadata and still rejects unknown deployment mode strings.</td>
    </tr>
    <tr>
      <td>Deploy resource gap classification</td>
      <td>2026-06-18 15:33:36 BST</td>
      <td>2026-06-18 15:33:36 BST</td>
      <td>2026-06-18 15:33:36 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Reclassified <code>deploy.resources.limits.pids</code>, <code>deploy.resources.limits.devices</code>, <code>deploy.resources.limits.generic_resources</code>, and <code>deploy.resources.reservations</code> from local deploy plugin backlog to Apple/container resource parity. Docker Compose deploy reservations require platform guarantees, while the current Apple/container create/run surface exposes local hard CPU and memory limits but no deploy PID, deploy device, generic resource, or reservation primitive.</td>
    </tr>
    <tr>
      <td>Volume nocopy support</td>
      <td>2026-06-18 12:25:21 BST</td>
      <td>2026-06-18 12:25:21 BST</td>
      <td>2026-06-18 12:25:21 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Accepted long-form service volume <code>volume.nocopy</code> as supported no-copy metadata. The Apple/container volume mount path already matches the requested no-copy behavior, so no runtime flag mapping is required.</td>
    </tr>
    <tr>
      <td>Volume subpath blocker classification</td>
      <td>2026-06-18 12:31:12 BST</td>
      <td>2026-06-18 12:31:12 BST</td>
      <td>2026-06-18 12:31:12 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Classified long-form service volume <code>volume.subpath</code> as an Apple/container mount primitive gap. Apple/container exposes named volume source, target, readonly, tmpfs size, and tmpfs mode, but no subpath selector for mounting only part of a named volume.</td>
    </tr>
    <tr>
      <td>Run capability overrides</td>
      <td>2026-06-18 10:16:25 BST</td>
      <td>2026-06-18 10:16:25 BST</td>
      <td>2026-06-18 10:20:55 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Added Docker Compose <code>run --cap-add</code> and <code>run --cap-drop</code> mapping to Apple/container one-off runtime capability flags.</td>
    </tr>
    <tr>
      <td>Hawkeye workflow alignment</td>
      <td>2026-06-18 10:23:56 BST</td>
      <td>2026-06-18 10:23:56 BST</td>
      <td>2026-06-18 10:40:06 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Added Hawkeye license-header tooling, adopted Apple/container&#x27;s build-once Swift coverage pattern, cached repo-local tools in CI, documented Apple/container upstream Compose parity gaps, and reformatted planning and compatibility docs for readability.</td>
    </tr>
  </tbody>
</table>

## Active Documentation Work

<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Added</th>
      <th>Started</th>
      <th>Completed</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>Add backlog tracking to <code>PLAN.md</code></td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 09:39:04 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Include plugin backlog and Apple/container upstream PR backlog.</td>
    </tr>
    <tr>
      <td>Reformat <code>BUILD.md</code> runtime boundary</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 09:39:04 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Split the dense runtime-boundary paragraph into readable responsibilities and adapter tables.</td>
    </tr>
    <tr>
      <td>Update <code>DESIGN.md</code> direct API discussion</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 09:39:04 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Explain that direct Apple/container APIs are preferred wherever available and how that works with compose-go normalization.</td>
    </tr>
    <tr>
      <td>Contributor and compatibility readability pass</td>
      <td>2026-06-18 10:57:58 BST</td>
      <td>2026-06-18 10:57:58 BST</td>
      <td>2026-06-18 11:05:06 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Reformat dense plan and compatibility status surfaces, align contributor guidance with Apple/container and Containerization contributor expectations, and document the adoption-friction goal.</td>
    </tr>
    <tr>
      <td>Adoption friction design note</td>
      <td>2026-06-18 11:17:32 BST</td>
      <td>2026-06-18 11:17:32 BST</td>
      <td>2026-06-18 11:18:08 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Make reducing friction for possible Apple/container adoption an explicit design constraint, with clear boundaries for Compose normalization, Swift orchestration, direct runtime API mapping, compatibility documentation, and upstream runtime primitive gaps.</td>
    </tr>
    <tr>
      <td>Focused topic workflow note</td>
      <td>2026-06-18 11:33:56 BST</td>
      <td>2026-06-18 11:33:56 BST</td>
      <td>2026-06-18 11:33:56 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Capture the implementation workflow preference to choose one Compose functional topic, drive it to completion or to a documented Apple/container blocker, and only then move to another topic. The existing adoption-friction guidance in <code>DESIGN.md</code> and <code>CONTRIBUTING.md</code> remains the review standard for keeping future Apple/container adoption practical.</td>
    </tr>
  </tbody>
</table>

## <span style="background:#FFF7D6;color:#7A4D00;border:1px solid #FFE380;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">ACTIVE</span> container-compose Backlog

These tasks are valid Docker Compose v2 surfaces where Apple/container is not
known to be the first blocker. The fix belongs in this repository unless deeper
Apple/container API work is discovered during implementation.

<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Added</th>
      <th>Started</th>
      <th>Completed</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td><code>watch</code> and develop workflows</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 09:44:11 BST</td>
      <td>2026-06-18 13:00:42 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> <code>develop.watch</code> is now supported for dry-run planning and live polling execution. Remaining C3 plugin work is tracked separately under providers and lifecycle hooks. Service model runtime behavior moved to the Apple/container upstream backlog after the model-runner boundary was confirmed.</td>
    </tr>
    <tr>
      <td>Replica scaling edge cases</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 10:07:04 BST</td>
      <td><span style="background:#FFF7D6;color:#7A4D00;border:1px solid #FFE380;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">ACTIVE</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Per-replica anonymous volume naming and collision safeguards for <code>container_name</code>, too-small fixed published-port ranges, and fixed MAC addresses are complete. Scaled service DNS is an Apple/container networking gap. Remaining plugin work covers broader deploy behavior.</td>
    </tr>
    <tr>
      <td>Local deploy interpretation</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 12:02:15 BST</td>
      <td>2026-06-18 17:12:16 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Standard Docker Compose local deploy interpretation is complete for the current model boundary. Explicit <code>deploy.mode: replicated</code> maps to existing replica orchestration; <code>deploy.mode: global</code>, <code>deploy.labels</code>, update metadata, rollback metadata, and placement metadata are accepted as Docker Compose local no-op metadata; CPU/memory deploy limits map to local runtime limits; and stop-first <code>deploy.update_config</code> including <code>delay</code> matches the existing recreate path. <code>deploy.restart_policy</code>, <code>deploy.endpoint_mode</code>, <code>deploy.resources.limits.pids</code>, <code>deploy.resources.limits.devices</code>, <code>deploy.resources.limits.generic_resources</code>, <code>deploy.resources.reservations</code>, and <code>deploy.update_config.order: start-first</code> are tracked with Apple/container runtime parity.</td>
    </tr>
    <tr>
      <td>Providers, models, and lifecycle hooks</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 13:23:28 BST</td>
      <td><span style="background:#FFF7D6;color:#7A4D00;border:1px solid #FFE380;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">ACTIVE</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Service <code>post_start</code> and <code>pre_stop</code> execution is implemented for detached service lifecycle paths, <code>post_start</code> is implemented for detached one-off <code>run</code>, and <code>pre_stop</code> is implemented for detached one-off cleanup when container-compose controls the stop. Provider service lifecycle support is tracked as a completed subtask below. Service <code>models</code> binding metadata is preserved for config output, but runtime model-runner behavior needs Apple/container model-runner parity. Attached <code>up</code> post-start ordering, foreground <code>run</code> post-start ordering, and foreground one-off <code>pre_stop</code> need Apple/container foreground attach or stop-boundary primitives.</td>
    </tr>
    <tr>
      <td>Provider service lifecycle</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 15:45:14 BST</td>
      <td>2026-06-18 16:03:27 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Provider services now preserve <code>provider.type</code> and <code>provider.options</code> from <code>compose-go</code>, run provider <code>compose metadata</code> plus <code>up</code>/<code>down</code>/advertised <code>stop</code>, validate required metadata parameters, filter unknown provider options when metadata is available, and inject provider <code>setenv</code> values into direct dependents for <code>up</code> and one-off <code>run</code> dependency startup. This is plugin-owned functionality; no Apple/container runtime PR is needed for provider process execution.</td>
    </tr>
    <tr>
      <td>Service model binding boundary</td>
      <td>2026-06-18 16:23:30 BST</td>
      <td>2026-06-18 16:23:30 BST</td>
      <td>2026-06-18 16:23:30 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Preserved service <code>models</code> binding metadata from <code>compose-go</code> instead of a boolean marker, including explicit <code>endpoint_var</code>/<code>model_var</code> names and defaulted bindings. Docker Compose model runtime behavior shells out to the Docker Model plugin to pull/configure models and discover an endpoint. Apple/container does not expose a Compose-compatible model runner, endpoint discovery, or guaranteed service-container reachability primitive yet, so runtime service model bindings now reject as an Apple/container model-runner parity gap before resources are created.</td>
    </tr>
    <tr>
      <td>Logging and storage metadata</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 14:20:37 BST</td>
      <td>2026-06-18 14:46:45 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Service <code>volume_driver: local</code> is supported. External-container <code>volumes_from</code> is supported for Apple/container volume, bind, and tmpfs mounts discovered through direct inspect. Logging driver/options, service <code>storage_opt</code>, non-local service volume drivers, image-declared inherited mounts, image mounts, external block mounts, and advanced bind/volume options are tracked as Apple/container runtime gaps.</td>
    </tr>
    <tr>
      <td>API socket and block I/O support</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 17:21:13 BST</td>
      <td>2026-06-18 17:21:13 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Classified both fields as Apple/container runtime gaps after reviewing Docker Compose and Apple/container behavior. Docker Compose implements <code>use_api_socket</code> as a client-side Docker socket plus credential handoff, while Apple/container can mount Unix sockets but does not expose a safe Docker-compatible API socket or credential boundary. Docker Compose maps <code>blkio_config</code> to Docker resource controls, while Apple/container reports block I/O stats but does not expose create/run blkio weight or throttling controls.</td>
    </tr>
  </tbody>
</table>

## <span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span> Apple/container Upstream Backlog

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

1. Networking parity: multi-network attachment, aliases, service-name
   multi-record DNS for replicas, Compose endpoint modes, fixed addresses, and
   richer IPAM.
2. Build parity: BuildKit-compatible inputs that Docker Compose v2 can express,
   including additional contexts, build networking, SSH, attestations, and
   advanced build secret metadata.
3. Container identity parity: hostname, domain name, host entries, and legacy
   link aliases.
4. Runtime-control parity: namespace modes, cgroups, privileged/device/GPU
   controls, sysctls, supplemental groups, deploy PID limits, and deploy
   resource reservations.
5. Mount and storage parity: advanced bind/volume/image mounts, storage
   options, non-local service volume drivers, and inherited image volumes.
6. Health and completion parity: health status, health-aware waits, stored exit
   code, and completion timestamps.
7. Start-first replacement parity: container rename or service alias handoff for
   Docker Compose compatible temporary replacement finalization.
8. Mount and policy parity: first-class config/secret stores or materialization,
   ownership/mode controls for non-file-backed grants, and restart policies.
9. Log-data parity: timestamped log records, stream/source metadata, tail and
   since/until filtering, prefix-friendly service/replica attribution, and
   durable closed-container log replay, plus service logging driver/option
   controls.
10. Interactive attach parity: reattach stdin/stdout/stderr to an already-running
   init process, proxy signals, support detach-key behavior, and expose the
   start-hook-reattach or stop-boundary primitives needed for foreground
   lifecycle hooks.
11. Command-data parity: events, process listing, pause/unpause, and copy
   archive/follow-link controls.
12. Image and artifact parity: container commit image snapshots and Compose
    application OCI artifact publish/consume support.
13. Model-runner parity: a Compose-compatible model runner backend, model
    pull/configure lifecycle, endpoint discovery, and service-container
    reachability for model endpoints.
14. Runtime API socket parity: a safe Compose-compatible equivalent for
    `use_api_socket` that does not overexpose host control surfaces.
15. Block I/O parity: create/run resource controls for `blkio_config` weight,
    per-device weight, and read/write byte or IOPS throttling.

<table>
  <thead>
    <tr>
      <th>Task</th>
      <th>Added</th>
      <th>Started</th>
      <th>Completed</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>Fork Apple/container for Compose primitive work</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Use the fork to stage small upstream PRs that unblock Compose compatibility.</td>
    </tr>
    <tr>
      <td>Multi-network attachment and aliases</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose needs multiple service networks, network aliases, richer per-network options, and attach/connect semantics.</td>
    </tr>
    <tr>
      <td>Compose service DNS aliases and replica lookups</td>
      <td>2026-06-18 11:56:51 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose service discovery needs network aliases, endpoint modes such as <code>vip</code> and <code>dnsrr</code>, plus DNS lookup that can return multiple A/AAAA records for scaled service names. Apple/container currently allocates one attachment per hostname, DNS lookup returns a single attachment, and container creation rejects duplicate attachment hostnames.</td>
    </tr>
    <tr>
      <td>Start-first service replacement handoff</td>
      <td>2026-06-18 16:48:46 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose <code>deploy.update_config.order: start-first</code> needs a temporary replacement handoff. Docker Compose creates a replacement under a temporary name, stops/removes the old stable container, then renames the replacement. Apple/container needs either a container rename primitive or service hostname/alias movement that can preserve the Compose service identity without duplicate ID or duplicate hostname conflicts.</td>
    </tr>
    <tr>
      <td>Fixed addresses and richer IPAM</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose needs fixed IPv4/IPv6 addresses, gateways, IP ranges, aux addresses, custom IPAM drivers, and multiple same-family subnets.</td>
    </tr>
    <tr>
      <td>BuildKit-compatible build inputs</td>
      <td>2026-06-18 10:34:11 BST</td>
      <td>2026-06-18 11:37:58 BST</td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose build parity needs additional contexts, build <code>extra_hosts</code>, build network modes, isolation, privileged builds, entitlements, SSH forwarding, advanced secret metadata (<code>uid</code>, <code>gid</code>, <code>mode</code>), build <code>shm_size</code>, build <code>ulimits</code>, and provenance/SBOM attestations exposed through Apple/container build APIs. Current <code>container build</code> supports the common local subset but not the full Compose v2 build surface.</td>
    </tr>
    <tr>
      <td>Host identity and host entries</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose needs hostname, domainname, extra host entries, and legacy link alias behavior.</td>
    </tr>
    <tr>
      <td>Namespace and cgroup controls</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose needs compatible <code>cgroup</code>, <code>cgroup_parent</code>, <code>ipc</code>, <code>pid</code>, <code>userns_mode</code>, <code>uts</code>, and isolation modes.</td>
    </tr>
    <tr>
      <td>Expanded resource controls</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 15:33:36 BST</td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose needs CPU scheduler controls beyond <code>cpus</code>, memory/swap/OOM/PID limits beyond current supported local limits, <code>deploy.resources.limits.pids</code>, <code>deploy.resources.limits.devices</code>, <code>deploy.resources.limits.generic_resources</code>, and <code>deploy.resources.reservations</code> platform guarantees for CPU, memory, PIDs, devices, and generic resources. Current Apple/container create/run surfaces expose local hard CPU and memory limits but not those deploy resource primitives.</td>
    </tr>
    <tr>
      <td>User, security, device, GPU, and sysctl controls</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose needs supplemental groups, security profiles, privileged containers and exec, host devices, GPUs, and per-container sysctls.</td>
    </tr>
    <tr>
      <td>Advanced mount and storage options</td>
      <td>2026-06-18 10:34:11 BST</td>
      <td>2026-06-18 14:20:37 BST</td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose needs bind propagation, SELinux flags, recursive/read-only bind behavior, volume subpaths, image mounts, mount consistency controls, non-local service volume drivers, service <code>storage_opt</code>, image-declared inherited mounts, and a safe Compose-compatible mapping for external inherited block mounts. Current Apple/container mount flags cover the common local subset only. External-container <code>volumes_from</code> is implemented for volume, bind, and tmpfs mounts that direct inspect can represent as Apple <code>container --volume</code> or <code>--mount type=tmpfs</code> arguments.</td>
    </tr>
    <tr>
      <td>Health status and dependency gates</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose needs health status and health-aware dependency waits for <code>service_healthy</code>.</td>
    </tr>
    <tr>
      <td>Container completion metadata</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose needs stored exit code and completion time so <code>service_completed_successfully</code> and already-stopped <code>wait</code> replay can work.</td>
    </tr>
    <tr>
      <td>Config and secret stores/materialization</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 17:49:27 BST</td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> File-backed service <code>configs</code> and <code>secrets</code> are implemented in container-compose through read-only bind mounts. Compose still needs first-class Apple/container config/secret stores or materialization for external definitions, inline config content, environment-backed runtime grants, and strict ownership/mode behavior that cannot be represented as a simple bind mount.</td>
    </tr>
    <tr>
      <td>Restart policies</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose needs service <code>restart</code> and <code>deploy.restart_policy</code> support compatible with local Docker Compose behavior.</td>
    </tr>
    <tr>
      <td>Compose model runner parity</td>
      <td>2026-06-18 16:23:30 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose service <code>models</code> need a model-runner backend that can pull/configure model artifacts, expose endpoint status, inject endpoint/model variables, and make those endpoints reachable from Apple/container service containers. Docker Compose currently delegates this to the Docker Model plugin; Apple/container does not expose an equivalent primitive.</td>
    </tr>
    <tr>
      <td>Docker Compose log parity</td>
      <td>2026-06-18 10:29:02 BST</td>
      <td>2026-06-18 14:20:37 BST</td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose <code>logs</code> needs runtime log records with timestamps, stdout/stderr stream metadata, since/until filtering, tailing handled by the runtime, service/replica attribution for prefix output, reliable replay for stopped containers, and service logging driver/option controls such as rotation policy. Current Apple/container APIs expose raw log handles, so container-compose can only approximate unprefixed local log output.</td>
    </tr>
    <tr>
      <td>Interactive init-process attach and signal proxying</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 14:12:23 BST</td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Docker Compose default <code>attach</code> needs stdin/stdout/stderr reattach to an already-running service init process, signal proxying, and detach-key handling. Attached <code>up</code> with <code>post_start</code> and foreground one-off <code>run</code> with lifecycle hooks need the same start-hook-reattach shape, plus an interceptable foreground stop boundary for <code>pre_stop</code>. Apple/container currently wires stdio while bootstrapping a container or creating a new exec process, but does not expose a Compose-compatible reattach primitive for an already-running service container.</td>
    </tr>
    <tr>
      <td>Dynamic host-port allocation</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td>2026-06-18 13:56:09 BST</td>
      <td>2026-06-18 14:06:00 BST</td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Completed in container-compose by allocating ephemeral host ports before invoking Apple/container with explicit <code>--publish</code> bindings. No Apple/container PR is needed for common local target-only, ranged, or host-bound published-port workflows.</td>
    </tr>
    <tr>
      <td>Runtime event stream and process listing</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose <code>events</code> and <code>top</code> need corresponding runtime APIs.</td>
    </tr>
    <tr>
      <td>Pause and unpause</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose <code>pause</code> and <code>unpause</code> need container pause primitives.</td>
    </tr>
    <tr>
      <td>Copy archive and follow-link controls</td>
      <td>2026-06-18 09:36:35 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose <code>cp --archive</code> and <code>cp --follow-link</code> need matching file copy controls.</td>
    </tr>
    <tr>
      <td>Container commit image snapshots</td>
      <td>2026-06-18 11:45:20 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose <code>commit</code> needs an Apple/container primitive that creates an image from a service container's changed filesystem and accepts Docker-compatible image metadata such as author, message, pause behavior, target replica index, and config changes.</td>
    </tr>
    <tr>
      <td>Compose application OCI artifacts</td>
      <td>2026-06-18 11:45:20 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose <code>publish</code> and <code>oci://</code> Compose file references need Apple/container image/registry primitives for publishing and consuming Compose application OCI artifacts, not only service image tag/push/save operations.</td>
    </tr>
    <tr>
      <td>Runtime API socket exposure</td>
      <td>2026-06-18 10:34:11 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose <code>use_api_socket</code> needs a safe Docker-compatible or Apple/container-compatible API socket exposure model, including credentials, least-privilege boundaries, and clear behavior when Docker API compatibility is unavailable.</td>
    </tr>
    <tr>
      <td>Block I/O resource controls</td>
      <td>2026-06-18 17:21:13 BST</td>
      <td><span style="background:#F4F5F7;color:#42526E;border:1px solid #DFE1E6;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">OPEN</span></td>
      <td><span style="background:#FFEBE6;color:#BF2600;border:1px solid #FFBDAD;border-radius:3px;padding:1px 6px;font-size:12px;font-weight:700;white-space:nowrap;">UPSTREAM GAP</span></td>
    </tr>
    <tr>
      <td colspan="4"><strong>Notes:</strong> Compose <code>blkio_config</code> needs Apple/container create/run resource primitives for blkio weight, per-device weight, and read/write byte or IOPS throttling. Current Apple/container APIs expose block I/O stats but not blkio resource-control configuration.</td>
    </tr>
  </tbody>
</table>

## Keeping This File Current

When a task moves:

1. Update the timestamp in this file.
2. Update [COMPATIBILITY.md](COMPATIBILITY.md) if the supported or blocked
   surface changes.
3. Add or update tests for the behavior.
4. Validate locally with the appropriate Makefile target before committing.
