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

### Log Runtime Direction

The log rows distinguish the local integration stack from the direction intended for [`apple/container`][apple-container]. The local [`logs-integration-chris` branch](https://github.com/stephenlclarke/container/tree/logs-integration-chris) is a proving branch built from Chris George's log retrieval direction, not a single upstream PR target. The intended runtime path is a sequence of small apple/container changes: keep retrieval filters separate from replay policy and presentation flags, add line-correct `tail`/`since`/`until` filtering after logical log-line reconstruction, add Docker-compatible timestamp parsing, add structured log records, add static rotated replay, add a bounded rotation-aware follow cursor or stream, then add local logging policy support for `json-file`, `local`, `none`, `max-size`, and `max-file`. This repository should update the compatibility rows as each runtime primitive becomes accepted upstream and should keep Compose-specific prefixing, service fan-out, and command formatting in the plugin.

### Upstream Log PR Dependencies

The local logging support depends on upstream `apple/container` changes that are still in review. Treat these PRs as dependency markers, not released runtime capabilities, until they merge upstream and this repository updates its pinned `apple/container` reference to an accepted release or commit.

- **Chris George, [apple/container#1592](https://github.com/apple/container/pull/1592):** <img alt="UPSTREAM OPEN" src="https://img.shields.io/badge/UPSTREAM%20OPEN-B26A00?style=flat-square"> Adds the base container log retrieval-options direction. This is the upstream anchor for moving log filtering into `ContainerClient` instead of keeping Compose-only replay workarounds in the plugin. `container-compose` must keep the current guarded local integration path until the option shape and ownership are accepted upstream.
- **Stephen Clarke, [apple/container#1764](https://github.com/apple/container/pull/1764):** <img alt="UPSTREAM OPEN" src="https://img.shields.io/badge/UPSTREAM%20OPEN-B26A00?style=flat-square"> Ready-for-review follow-up that adds `tail` and `until` retrieval filters on top of #1592. This is the proposed runtime surface for Docker Compose `logs --tail` and `logs --until`, but `container-compose` should continue marking release support as waiting on upstream until #1592/#1764 land with line-correct filtering semantics.
- **Stephen Clarke, [apple/container#1765](https://github.com/apple/container/pull/1765):** <img alt="UPSTREAM OPEN" src="https://img.shields.io/badge/UPSTREAM%20OPEN-B26A00?style=flat-square"> Ready-for-review follow-up that adds Docker-compatible timestamp and duration parsing for log filters on top of #1592/#1764. This is the proposed shared parser for Docker-compatible `--since` and `--until` values. `container-compose` should not remove its compatibility parser or claim released upstream parity until the parser API is accepted and available through the pinned `apple/container` dependency.

Until those upstream changes are accepted, Compose-specific behavior stays in this repository: service fan-out, replica prefixes, color/no-prefix rendering, selected-service ordering, and Docker Compose CLI formatting. The `apple/container` PRs should remain runtime-only primitives so they can be adopted upstream without carrying `container-compose` policy into the core runtime.

### Current apple/container PR And Issue Watchlist

Reviewed against open [`apple/container`][apple-container] pull requests and issues on `2026-06-20`. A pull request is treated as non-stale when it is open and has recent activity, or when it is an active review branch tied to a Compose runtime primitive. Older issues are still listed when they define a runtime or API surface that directly unblocks Docker Compose v2 behavior in this repository.

#### Pull Requests To Merge Or Track In The Fork

- **Logs:** <img alt="FORK MERGE" src="https://img.shields.io/badge/FORK%20MERGE-2563EB?style=flat-square"> [apple/container#1592](https://github.com/apple/container/pull/1592), [apple/container#1764](https://github.com/apple/container/pull/1764), and [apple/container#1765](https://github.com/apple/container/pull/1765) are the first log-runtime stack for Compose `logs --tail`, `logs --since`, `logs --until`, timestamp parsing, and a direct client-side filtering contract. [apple/container#1758](https://github.com/apple/container/pull/1758) is low-risk log handler hygiene that should stay with the log stack but is not itself a Compose feature.
- **Health, completion, and restart:** <img alt="FORK MERGE" src="https://img.shields.io/badge/FORK%20MERGE-2563EB?style=flat-square"> [apple/container#1503](https://github.com/apple/container/pull/1503), [apple/container#1504](https://github.com/apple/container/pull/1504), [apple/container#1562](https://github.com/apple/container/pull/1562), and [apple/container#1258](https://github.com/apple/container/pull/1258) unblock `depends_on.condition: service_healthy`, `depends_on.condition: service_completed_successfully`, `wait`, stopped-container exit replay, and Compose `restart` / `deploy.restart_policy` mapping. These should be tested together in the fork because Compose depends on the combined lifecycle contract.
- **Host entries, DNS, and network identity:** <img alt="FORK MERGE" src="https://img.shields.io/badge/FORK%20MERGE-2563EB?style=flat-square"> [apple/container#1563](https://github.com/apple/container/pull/1563) and [apple/container#1340](https://github.com/apple/container/pull/1340) directly map to Compose `extra_hosts`. [apple/container#1740](https://github.com/apple/container/pull/1740) helps deterministic address behavior across stop/start. [apple/container#1614](https://github.com/apple/container/pull/1614) helps service DNS configuration. [apple/container#1463](https://github.com/apple/container/pull/1463), [apple/container#1622](https://github.com/apple/container/pull/1622), and [apple/container#1661](https://github.com/apple/container/pull/1661) are competing or complementary bridge-networking directions; test only one coherent bridge direction in the fork after comparing API shape.
- **Build, registry, and image parity:** <img alt="FORK MERGE" src="https://img.shields.io/badge/FORK%20MERGE-2563EB?style=flat-square"> [apple/container#1768](https://github.com/apple/container/pull/1768) maps to local insecure registry workflows. [apple/container#1508](https://github.com/apple/container/pull/1508), [apple/container#1739](https://github.com/apple/container/pull/1739), and [apple/container#1391](https://github.com/apple/container/pull/1391) improve Compose build compatibility and performance. [apple/container#1215](https://github.com/apple/container/pull/1215), [apple/container#1335](https://github.com/apple/container/pull/1335), [apple/container#1598](https://github.com/apple/container/pull/1598), [apple/container#1769](https://github.com/apple/container/pull/1769), [apple/container#1772](https://github.com/apple/container/pull/1772), and [apple/container#1720](https://github.com/apple/container/pull/1720) improve image, registry, `info`, import/load, and `images` command parity used by Compose workflows.
- **Copy, export, storage, and volumes:** <img alt="FORK MERGE" src="https://img.shields.io/badge/FORK%20MERGE-2563EB?style=flat-square"> [apple/container#1741](https://github.com/apple/container/pull/1741) fixes relative host paths for Compose `cp`. [apple/container#1630](https://github.com/apple/container/pull/1630) improves live export workflows. [apple/container#1428](https://github.com/apple/container/pull/1428) adds network-backed volume drivers that can eventually map non-local Compose volume drivers.
- **Plugin and runtime API shape:** <img alt="WATCH" src="https://img.shields.io/badge/WATCH-6B7280?style=flat-square"> [apple/container#1774](https://github.com/apple/container/pull/1774), [apple/container#1701](https://github.com/apple/container/pull/1701), [apple/container#1618](https://github.com/apple/container/pull/1618), and [apple/container#717](https://github.com/apple/container/pull/717) can affect direct client dependencies, runtime abstraction, or external plugin installation. They should be monitored for API/install-layout impact rather than merged blindly into the fork.
- **Peer Compose implementation:** <img alt="COORDINATE" src="https://img.shields.io/badge/COORDINATE-0891B2?style=flat-square"> [apple/container#1736](https://github.com/apple/container/pull/1736) overlaps with Compose command behavior and examples. Do not merge it into this external-plugin branch wholesale; compare fixtures, CLI expectations, and maintainer feedback with this repository before copying any focused tests or examples.

#### Issues That Would Progress container-compose If Addressed

- **Logs and logging policy:** <img alt="IMPLEMENT" src="https://img.shields.io/badge/IMPLEMENT-7C3AED?style=flat-square"> [apple/container#1752](https://github.com/apple/container/issues/1752), [apple/container#1591](https://github.com/apple/container/issues/1591), and [apple/container#1754](https://github.com/apple/container/issues/1754) define the immediate log runtime work for Compose `logs`, line-correct replay, timestamp filters, rotated replay, follow cursors, and clean log handler APIs.
- **Health, jobs, completion, and events:** <img alt="IMPLEMENT" src="https://img.shields.io/badge/IMPLEMENT-7C3AED?style=flat-square"> [apple/container#1501](https://github.com/apple/container/issues/1501), [apple/container#1502](https://github.com/apple/container/issues/1502), [apple/container#286](https://github.com/apple/container/issues/286), [apple/container#484](https://github.com/apple/container/issues/484), and [apple/container#378](https://github.com/apple/container/issues/378) cover exit metadata, health metadata, restart policies, events, and attach. These are the runtime gates for `depends_on` health/completion conditions, `events`, `attach`, `wait`, and restart-policy parity.
- **Networks, DNS, aliases, and addresses:** <img alt="IMPLEMENT" src="https://img.shields.io/badge/IMPLEMENT-7C3AED?style=flat-square"> [apple/container#1283](https://github.com/apple/container/issues/1283), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#500](https://github.com/apple/container/issues/500), [apple/container#1320](https://github.com/apple/container/issues/1320), [apple/container#282](https://github.com/apple/container/issues/282), [apple/container#489](https://github.com/apple/container/issues/489), and [apple/container#670](https://github.com/apple/container/issues/670) cover the core networking primitives Compose still lacks: multi-network attach, per-network aliases, interface DNS names, internal networks without host access, fixed IPs, bridge mode, and Docker-style container network modes.
- **Network reliability blockers:** <img alt="WATCH" src="https://img.shields.io/badge/WATCH-6B7280?style=flat-square"> [apple/container#1519](https://github.com/apple/container/issues/1519), [apple/container#1307](https://github.com/apple/container/issues/1307), [apple/container#1241](https://github.com/apple/container/issues/1241), [apple/container#817](https://github.com/apple/container/issues/817), [apple/container#856](https://github.com/apple/container/issues/856), [apple/container#402](https://github.com/apple/container/issues/402), [apple/container#989](https://github.com/apple/container/issues/989), and [apple/container#1737](https://github.com/apple/container/issues/1737) are not all new features, but they affect whether real Compose stacks can reliably reach DNS, host services, VPN-routed resources, or images with difficult `/etc` layouts.
- **Build and Dockerfile parity:** <img alt="IMPLEMENT" src="https://img.shields.io/badge/IMPLEMENT-7C3AED?style=flat-square"> [apple/container#1766](https://github.com/apple/container/issues/1766), [apple/container#1472](https://github.com/apple/container/issues/1472), [apple/container#1515](https://github.com/apple/container/issues/1515), [apple/container#701](https://github.com/apple/container/issues/701), [apple/container#453](https://github.com/apple/container/issues/453), [apple/container#451](https://github.com/apple/container/issues/451), [apple/container#452](https://github.com/apple/container/issues/452), [apple/container#522](https://github.com/apple/container/issues/522), and [apple/container#440](https://github.com/apple/container/issues/440) cover build args, SSH mounts, context performance, BuildKit option passthrough, build secrets, cache import/export, platform args, and Dockerfile `HEALTHCHECK`.
- **Registry, image, and platform parity:** <img alt="IMPLEMENT" src="https://img.shields.io/badge/IMPLEMENT-7C3AED?style=flat-square"> [apple/container#731](https://github.com/apple/container/issues/731), [apple/container#820](https://github.com/apple/container/issues/820), [apple/container#816](https://github.com/apple/container/issues/816), [apple/container#1707](https://github.com/apple/container/issues/1707), [apple/container#1334](https://github.com/apple/container/issues/1334), [apple/container#1426](https://github.com/apple/container/issues/1426), and [apple/container#913](https://github.com/apple/container/issues/913) cover insecure registries, credential helpers, private registry pull/push failures, all-tags push, legacy Docker archive load, and consistent multi-platform semantics.
- **Storage, mounts, and volume drivers:** <img alt="IMPLEMENT" src="https://img.shields.io/badge/IMPLEMENT-7C3AED?style=flat-square"> [apple/container#1413](https://github.com/apple/container/issues/1413), [apple/container#895](https://github.com/apple/container/issues/895), [apple/container#729](https://github.com/apple/container/issues/729), [apple/container#889](https://github.com/apple/container/issues/889), and [apple/container#165](https://github.com/apple/container/issues/165) cover non-local volume drivers, volume copy/seed behavior, read-only shared named volumes, and UID/GID-sensitive bind mount behavior.
- **Plugin, SDK, and command UX:** <img alt="WATCH" src="https://img.shields.io/badge/WATCH-6B7280?style=flat-square"> [apple/container#630](https://github.com/apple/container/issues/630), [apple/container#633](https://github.com/apple/container/issues/633), [apple/container#462](https://github.com/apple/container/issues/462), [apple/container#464](https://github.com/apple/container/issues/464), [apple/container#381](https://github.com/apple/container/issues/381), and [apple/container#642](https://github.com/apple/container/issues/642) help external plugin adoption, direct API documentation, system health diagnostics, and Docker-compatible stdout/stderr behavior.

#### Recommended Fork Action List

1. <img alt="FORK MERGE" src="https://img.shields.io/badge/FORK%20MERGE-2563EB?style=flat-square"> Keep the fork's log branch aligned with Chris George's [apple/container#1592](https://github.com/apple/container/pull/1592), then layer [apple/container#1764](https://github.com/apple/container/pull/1764) and [apple/container#1765](https://github.com/apple/container/pull/1765) for end-to-end Compose log validation.
2. <img alt="FORK MERGE" src="https://img.shields.io/badge/FORK%20MERGE-2563EB?style=flat-square"> Merge or cherry-pick the health/exit/restart PR set into a fork integration branch and add Compose integration tests for `service_healthy`, `service_completed_successfully`, `restart`, `wait`, and failed one-shot jobs.
3. <img alt="FORK MERGE" src="https://img.shields.io/badge/FORK%20MERGE-2563EB?style=flat-square"> Test `extra_hosts`, explicit host entries, sticky IPs, DNS defaults, and one chosen bridge-networking direction together before exposing more networking fields in `container-compose`.
4. <img alt="IMPLEMENT" src="https://img.shields.io/badge/IMPLEMENT-7C3AED?style=flat-square"> Slice new small apple/container PRs for the remaining unimplemented issue groups: events, attach, multi-network aliases, fixed IPs, BuildKit option passthrough, build `HEALTHCHECK`, and volume seed/copy behavior.
5. <img alt="COORDINATE" src="https://img.shields.io/badge/COORDINATE-0891B2?style=flat-square"> Compare the peer Compose PR [apple/container#1736](https://github.com/apple/container/pull/1736) and related plugin ergonomics work before copying code. Reuse only focused tests, examples, or API lessons that fit this repo's external-plugin architecture.

### Supported

Docker Compose v2 accepts the surface, [`apple/container`][apple-container] exposes the needed primitive, and `container-compose` maps it. Runtime work executes through [`apple/container`][apple-container] APIs or CLI commands. No compatibility fix is needed.

### [`apple/container`][apple-container] Gap

Docker Compose v2 accepts the surface, but [`apple/container`][apple-container] is missing the primitive, has incomplete behavior, or does not expose the behavior through a usable API. `container-compose` rejects the field before resources are created with an `apple/container` runtime gap message. The fix starts upstream in [`apple/container`][apple-container], then this repo maps the new primitive.

### `container-compose` Gap

Docker Compose v2 accepts the surface and [`apple/container`][apple-container] is not known to be the first blocker, but this plugin does not map it yet. `container-compose` rejects the field before resources are created with a plugin implementation message. The fix belongs in this repository.

### Config-Only

Docker Compose v2 accepts the surface and runtime support is not needed for normalized `config` output. `container-compose` preserves the data for `config` and `convert`; runtime commands either ignore harmless metadata or reject service-level use when the requested behavior has no supported runtime mapping.

## Status Lozenges

The lozenges use static flat badge images so the traffic-light colours render
inside GitHub Markdown and HTML tables: green is supported/no-gap, yellow is
partial, red is blocked by [`apple/container`][apple-container], orange is
blocked in this repository, blue is a fork-merge candidate, purple is an
implementation candidate, cyan is a coordination point, and gray is
config-only or watch-only.

- <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">: Docker Compose v2 accepts the surface, [`apple/container`][apple-container] has the required primitive, and `container-compose` maps it.
- <img alt="NO PLUGIN GAP" src="https://img.shields.io/badge/NO%20PLUGIN%20GAP-2E7D32?style=flat-square">: no current runtime or command surface is blocked first by this repository.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">: the common local workflow is supported, but adjacent Compose behavior still depends on an [`apple/container`][apple-container] runtime gap.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">: the first missing piece is an [`apple/container`][apple-container] runtime primitive.
- <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square">: [`apple/container`][apple-container] is not known to be the blocker and this repository still needs implementation work.
- <img alt="CONFIG ONLY" src="https://img.shields.io/badge/CONFIG%20ONLY-6B7280?style=flat-square">: normalized output is preserved, but runtime behavior is not applied.
- <img alt="UPSTREAM OPEN" src="https://img.shields.io/badge/UPSTREAM%20OPEN-B26A00?style=flat-square">: the referenced [`apple/container`][apple-container] pull request is open and not yet a released dependency.
- <img alt="FORK MERGE" src="https://img.shields.io/badge/FORK%20MERGE-2563EB?style=flat-square">: a candidate for the fork or a fork integration branch after local review and conflict checks.
- <img alt="IMPLEMENT" src="https://img.shields.io/badge/IMPLEMENT-7C3AED?style=flat-square">: an upstream issue that can be implemented as a small [`apple/container`][apple-container] pull request or carried temporarily in the fork.
- <img alt="COORDINATE" src="https://img.shields.io/badge/COORDINATE-0891B2?style=flat-square">: related peer work that should be compared or discussed before copying code or opening overlapping PRs.
- <img alt="WATCH" src="https://img.shields.io/badge/WATCH-6B7280?style=flat-square">: useful upstream movement to monitor, but not a direct fork merge target yet.

## Compatibility Snapshot

<table>
  <thead>
    <tr>
      <th>Area</th>
      <th>Status</th>
      <th>Meaning</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>Common local Compose workflows</td>
      <td><img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"></td>
      <td>The supported matrix covers the local-development path where Docker Compose v2, apple/container, and this plugin all have matching behavior; partial rows call out adjacent apple/container gaps.</td>
    </tr>
    <tr>
      <td>apple/container primitive gaps</td>
      <td><img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"></td>
      <td>The Compose surface is valid, but the first missing piece is an apple/container runtime, build, networking, storage, logging, or command-data primitive.</td>
    </tr>
    <tr>
      <td>container-compose design gaps</td>
      <td><img alt="NO PLUGIN GAP" src="https://img.shields.io/badge/NO%20PLUGIN%20GAP-2E7D32?style=flat-square"></td>
      <td>No current runtime or command surface is blocked first by this repository. New plugin-owned gaps should be marked with <img alt="PLUGIN GAP" src="https://img.shields.io/badge/PLUGIN%20GAP-D97706?style=flat-square"> until implemented.</td>
    </tr>
    <tr>
      <td>Normalized metadata only</td>
      <td><img alt="CONFIG ONLY" src="https://img.shields.io/badge/CONFIG%20ONLY-6B7280?style=flat-square"></td>
      <td>The data is preserved for <code>config</code> and <code>convert</code>; runtime commands either ignore harmless metadata or reject service-level use when no supported mapping exists.</td>
    </tr>
  </tbody>
</table>

## Support Matrix

Each entry below is written as a compact status card:

- **Status:** Whether the surface is supported, partial, blocked upstream, blocked in this plugin, or config-only.
- **Compose surface:** The Compose v2 fields or CLI commands covered by the row.
- **apple/container path:** The runtime API or CLI primitive that can implement it, or the missing primitive that blocks it.
- **container-compose status:** What this plugin does today.
- **Examples:** Links to runnable examples later in this file.

### Supported By apple/container And container-compose

These surfaces have all three pieces: Docker Compose v2 model support, [`apple/container`][apple-container] runtime support, and plugin orchestration.

#### Config normalization

- **Status:** <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">
- **Compose surface:**
  - File discovery, repeated `-f`, `.env`, `--env-file`, interpolation, merge, profiles, `--project-directory`, and `-p/--project-name`.
  - Canonical `config` and `convert` JSON.
- **apple/container path:** No runtime primitive is needed.
- **container-compose status:** Supported through `compose-go` normalization.
- **Examples:** [S1](#s1-supported-local-web-stack), [O1](#o1-config-only-metadata).

#### Build and images

- **Status:** <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">
- **Compose surface:**
  - Build inputs: `build.context`, `build.dockerfile`, `build.dockerfile_inline`, `build.args`, `build.cache_from`, `build.cache_to`, `build.labels`, `build.platforms`, `build.target`, `build.no_cache`, `build.pull`, `build.tags`, and file-backed or environment-backed `build.secrets`.
  - Build commands: `build --no-cache`, `build --pull`, `build --push`, `build --quiet/-q`, and `build --with-dependencies`.
  - Image commands: `pull`, `push`, `images`, and image removal through `down --rmi local/all`.
  - Pull policies: global `up --pull`, `create --pull`, one-off `run --pull`, and service `pull_policy` values `always`, `missing`, `if_not_present`, `never`, `build`, `daily`, `weekly`, and `every_<duration>`.
- **apple/container path:**
  - Build runs through `container build --pull --quiet --platform --cache-in --cache-out --tag --label --secret --file`.
  - Image operations use direct `ClientImage.pull`, `ClientImage.get`, `ClientImage.push`, `ClientImage.delete`, `ClientImage.cleanUpOrphanedBlobs()`, and project discovery through `ContainerClient.list(filters:)`.
  - `build.dockerfile_inline` is materialized to a temporary Dockerfile.
- **container-compose status:** Supported for the listed local-development subset.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Container lifecycle

- **Status:** <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">
- **Compose surface:**
  - Project lifecycle: `create`, `up`, `down`, `start`, `stop`, `restart`, `rm`, `kill`, and `wait`.
  - Reconciliation: deterministic names, indexed replicas, one-off names, config-hash recreate, `--force-recreate`, `--no-recreate`, `--remove-orphans`, and `down --rmi local/all`.
  - Scaling: `up --scale`, `create --scale`, standalone `scale`, `scale --no-deps`, service `scale`, local `deploy.mode: replicated`, local no-op `deploy.mode: global`, local `deploy.replicas`, `deploy.update_config.order: stop-first`, `deploy.update_config.delay` between recreated replicas, and Docker Compose local no-op deploy metadata such as `deploy.update_config.parallelism`, `deploy.rollback_config`, and `deploy.placement`.
  - Options: `up --no-start`, `up --always-recreate-deps`, timeouts, service `attach: false`, `rm --force/-f`, `wait --down-project`, `run --rm`, `run --detach/-d`, and `run --name`.
  - Lifecycle hooks: service `post_start` and `pre_stop` for detached service starts, `start`, `stop`, `restart`, `down`, service recreation, and replica pruning; service `post_start` for detached one-off `run`; service `pre_stop` for detached one-off cleanup when `container-compose` later stops the one-off container through project cleanup.
- **apple/container path:** `container create`, `container run`, `ContainerClient.bootstrap`, `ClientProcess.start`, `ClientProcess.wait`, `ContainerClient.get`, `ContainerClient.list`, `ContainerClient.stop`, `ContainerClient.delete`, `ContainerClient.kill`, and direct process exec through `ContainerClient.createProcess` / `ClientProcess.start`.
- **container-compose status:** Supported for running or stopping service containers. `post_start` runs after service containers are started through a detached service lifecycle path and after detached one-off `run`; `pre_stop` runs before service-aware stops and before detached one-off containers are stopped through cleanup such as `up --remove-orphans` or `down --remove-orphans`. Compose job deploy modes, already-stopped wait replay, attached `up` with `post_start`, foreground one-off `run` with `post_start`, and foreground one-off `run` with `pre_stop` remain apple/container completion, scheduler, attach, or stop-boundary gaps.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Project discovery

- **Status:** <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">
- **Compose surface:** `ls`, `ls --all/-a`, `ls --format table/json`, `ls --quiet/-q`, and `ls --filter name=...`.
- **apple/container path:** `ContainerClient.list(filters:)` and Compose project/config-hash labels.
- **container-compose status:** Supported from labels on created containers.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Container interaction

- **Status:** <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">
- **Compose surface:**
  - Discovery and output: `ps`, filtered `ps`, prefixed `logs` across selected service replicas, colored log prefixes when ANSI policy allows them, concurrent `logs --follow`, indexed `logs`, fixture-covered blank-line/trailing-newline handling, non-UTF-8-preserving log replay/follow, static and followed `logs --timestamps`, `logs --no-color`, `logs --no-log-prefix`, static and followed `logs --since` and `logs --until` with RFC 3339, Unix timestamp, and relative-duration filters, output-only `attach --no-stdin --sig-proxy=false`, and indexed attach.
  - Exec: default stdin/TTY behavior, `-T/--no-tty`, `--interactive=false`, detached exec, env/user/workdir overrides, and indexed service targets.
  - File movement: service-aware `cp`, service-to-service `cp`, indexed `cp`, `cp --all`, one-off copy target discovery, and `export`.
  - Runtime queries: published-port `port`, indexed `port`, dynamically allocated and host-bound port lookup after container creation, `stats`, `stats --all`, `stats --format table/json`, `stats --no-stream`, and `version`.
- **apple/container path:** Direct `ContainerClient` list/get/logs/logRecords/logRecordFile/copy/export/stats APIs, `ProcessIO`, `ContainerClient.createProcess`, and `ClientProcess.start`. Static `logs --since`, `logs --until`, and `logs --timestamps` use the local [`logs-integration-chris`](https://github.com/stephenlclarke/container/tree/logs-integration-chris) log-options and structured log-record API work, which keeps `ContainerLogOptions` focused on retrieval filters and `ContainerLogReplayOptions` focused on replay policy; the local apple/container CLI accepts RFC 3339, RFC 3339 nano, Unix timestamp, and relative-duration filters, renders static `container logs --timestamps`, renders followed `container logs --follow --timestamps/--since/--until` from active structured record files, renders raw follow from active raw log handles, and exposes static rotated raw and structured replay through replay options. The open upstream path starts with Chris George's [apple/container#1592](https://github.com/apple/container/pull/1592), then the ready-for-review [apple/container#1764](https://github.com/apple/container/pull/1764) and [apple/container#1765](https://github.com/apple/container/pull/1765) follow-ups; this repository must wait for accepted upstream APIs before treating those local integration capabilities as released apple/container support.
- **container-compose status:** Supported for the listed direct API paths on the local integration stack. Static raw/timestamped log replay requests can include rotated local log files where apple/container exposes them. Static timestamped and time-window rendering delegates `tail`, `since`, and `until` to the direct apple/container structured record API, then renders the returned line-correct records locally. Followed structured streams use the active `ContainerClient.logRecordFile(id:)` JSONL file with a bounded cursor and use direct runtime status to flush an unterminated final line once the target container is no longer live. Raw rotated follow still uses plugin-side merged replay polling until apple/container exposes a first-class cursor or stream. Time filters accept RFC 3339 timestamps, RFC 3339 nano timestamps, Unix timestamps in seconds with optional fractional seconds, and relative durations. Line-boundary tests cover empty logs, blank records, final newlines, CRLF/CR separators, prefixed blank records, split structured records, and unterminated final records. Released timestamped follow, filtered log follow, static rotated replay, and byte-preserving structured log support wait for upstream apple/container acceptance of the #1592/#1764/#1765 retrieval/parser stack and subsequent structured record APIs; rotation-aware follow still needs an upstream cursor or stream design. Released structured stdout/stderr log identity semantics and runtime process/event controls remain apple/container gaps or compatibility decisions.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Develop watch workflows

- **Status:** <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">
- **Compose surface:** `watch`, `watch --dry-run`, `watch --no-up`, `watch --no-prune`, `watch --quiet`, selected services, and normalized `develop.watch` triggers for `sync`, `sync+restart`, `sync+exec`, `restart`, and `rebuild`.
- **apple/container path:** Dry-run validation does not mutate runtime state. Live watch uses direct copy, exec, lifecycle restart, build, and image prune paths where apple/container exposes them.
- **container-compose status:** Supported for polling-based local file watching, initial sync, changed-file sync, deleted-file cleanup, sync exec hooks, restarts, rebuilds, and rebuild pruning. `develop.watch` metadata is harmless for ordinary `up` and `run`.
- **Example:** [C3](#c3-partial-develop-providers-and-hooks).

#### Provider services

- **Status:** <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">
- **Compose surface:** Service `provider.type`, `provider.options`, provider `compose metadata`, provider `compose up`, provider `compose down`, optional provider `compose stop`, provider `info`/`debug`/`error`/`setenv` messages, and provider environment injection into direct dependents.
- **apple/container path:** Provider services are non-container lifecycle hooks. No apple/container runtime primitive is needed until a provider's returned values are injected into dependent service container environment variables.
- **container-compose status:** Supported for local `up`, dependency startup for one-off `run`, `down`, and advertised `stop`. Providers are resolved as an executable path, `docker-<type>` in `PATH`, or `<type>` in `PATH`; required metadata parameters are validated before invoking provider `up`/`down`; unknown provider options are filtered when metadata is available.
- **Example:** [S2](#s2-supported-provider-service).

#### Default networking

- **Status:** <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">
- **Compose surface:**
  - One service network, default project networks, external networks, `network_mode: none`, project network `internal`, and one IPv4 plus one IPv6 project network IPAM `subnet`.
  - Explicit host-published ports, target-only dynamically allocated host ports, and host-bound dynamic ports for `create`, `up`, and one-off `run`.
  - Scaled published-port ranges with enough explicit host ports for every replica, plus target-only and host-bound dynamic allocation per service replica.
  - Single-network `mac_address` and MTU through `driver_opts.com.docker.network.driver.mtu`.
- **apple/container path:** Direct `NetworkClient.create`, `NetworkConfiguration`, `NetworkClient.delete`, plus supported `container create/run --network` and explicit `--publish` flags where a direct adapter is not available yet. Target-only and host-bound Compose ports are allocated by the plugin before invoking apple/container.
- **container-compose status:** Supported for the listed single-network local subset.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Default storage

- **Status:** <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">
- **Compose surface:**
  - Named volumes, external volumes, bind mounts, read-only mounts, anonymous volumes, and deterministic per-replica anonymous volume names.
  - File-backed service `configs` and `secrets` mounted read-only at Compose-compatible targets.
  - Top-level volume `driver`, `driver_opts`, and `labels`.
  - Service-level `volume_driver: local` for the default local volume driver.
  - Tmpfs mounts, including long-form `tmpfs.size` and `tmpfs.mode`.
  - Same-project `volumes_from` for declared Compose mounts with `ro`/`rw` overrides.
  - External-container `volumes_from` for apple/container volume, bind, and tmpfs mounts discovered through direct container inspection, with `ro`/`rw` overrides.
  - One-off `run --volume/-v`, runtime-scoped `volumes`, quiet/json volume output, `rm --volumes/-v`, and `down --volumes`.
- **apple/container path:** Direct `ClientVolume.create`, `ClientVolume.list`, `ClientVolume.delete`, and `ContainerClient.get` snapshot inspection, plus supported `container create/run --volume`, `--tmpfs`, and `--mount type=tmpfs` flags.
- **container-compose status:** Supported for declared Compose mounts, project-scoped volumes, file-backed service `configs` and `secrets`, same-project and external `volumes_from`, the default local service `volume_driver`, and explicit `volume.nocopy` no-copy behavior.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Common runtime options

- **Status:** <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">
- **Compose surface:**
  - Process options: `command`, `entrypoint`, one-off `run --entrypoint`, `working_dir`, one-off `run --workdir`, `user`, one-off `run --user`, `tty`, one-off `run -T/--no-tty`, and `stdin_open`.
  - Runtime options: `container_name`, `read_only`, `init`, `platform`, `runtime`, DNS settings, capabilities, CPU/memory local limits, `shm_size`, `ulimits`, `stop_signal`, and `stop_grace_period`.
- **apple/container path:** Supported `container create/run` flags and `ContainerClient.stop(id:opts:)`.
- **container-compose status:** Supported for the listed local-development runtime options.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Environment and metadata

- **Status:** <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">
- **Compose surface:** Service `environment`, `env_file`, one-off env and label flags, service labels, service annotations, `deploy.labels` service metadata, `label_file`, network labels, volume labels, and Compose project/service/config-hash labels.
- **apple/container path:** Supported `container create/run --env`, `--env-file`, and resource/container labels.
- **container-compose status:** Supported. Service annotations are mapped to runtime metadata labels. `deploy.labels` are preserved as service metadata but are not applied as container labels.
- **Example:** [S1](#s1-supported-local-web-stack).

#### Simple ordering

- **Status:** <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">
- **Compose surface:** `depends_on` with no condition or `condition: service_started`, same-project `volumes_from` implicit dependencies, optional dependencies, `depends_on.<service>.restart: true` for single-replica restarts, `up --always-recreate-deps`, `up --no-deps`, and `run --no-deps`.
- **apple/container path:** Plugin dependency ordering, dependency-change tracking, `ContainerClient.stop(id:opts:)`, and `ContainerClient.start(id:)`.
- **container-compose status:** Supported for service-started ordering and selected dependency traversal behavior.
- **Example:** [S1](#s1-supported-local-web-stack).

### Blocked By apple/container

These are valid Docker Compose v2 surfaces. `container-compose` recognizes them, but [`apple/container`][apple-container] does not expose a Docker Compose compatible runtime primitive yet.

#### Rich network attachment and IPAM controls

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** Multiple service networks, aliases, service-name DNS for replicas, `deploy.endpoint_mode`, fixed addresses, network priority/interface fields, `network_mode` values other than `none`, and richer project IPAM fields.
- **Missing apple/container primitive:** Multi-network attach/connect, per-network aliases/options beyond MAC and MTU, VIP/DNSRR service endpoint discovery, multi-record DNS lookup for scaled service names, fixed addresses, Docker-compatible namespace modes, and richer project network IPAM controls.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A1](#a1-apple-gap-networking).

#### Host identity and legacy links

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** `hostname`, `domainname`, `extra_hosts`, `links`, and `external_links`.
- **Missing apple/container primitive:** Hostname/domain controls, explicit host entries, and legacy link/alias semantics.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A2](#a2-apple-gap-host-identity-and-links).

#### Namespace and resource controls

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** `cgroup`, `cgroup_parent`, `ipc`, `pid`, `userns_mode`, `uts`, `isolation`, CPU scheduler controls beyond supported `cpus`, memory/OOM/PID controls beyond supported `mem_limit`, `deploy.resources.limits.pids`, `deploy.resources.limits.devices`, `deploy.resources.limits.generic_resources`, and `deploy.resources.reservations`.
- **Missing apple/container primitive:** Namespace selection, parent cgroups, CPU scheduler controls beyond `cpus`, memory controls beyond `mem_limit`, swap/OOM/PID controls, deploy PID/device/generic-resource limits, and platform resource reservation guarantees.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A3](#a3-apple-gap-runtime-controls).

#### User, security, devices, and kernel tuning

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** `group_add`, `security_opt`, service `privileged`, `exec --privileged`, `credential_spec`, `device_cgroup_rules`, `devices`, `gpus`, and `sysctls`.
- **Missing apple/container primitive:** Supplemental groups, security profiles beyond supported `cap_add`/`cap_drop`, privileged mode, host devices, GPUs, per-container sysctls, and privileged exec processes.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A3](#a3-apple-gap-runtime-controls).

#### Health, completion, config/secret stores, service restart

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** `healthcheck`, `depends_on.condition: service_healthy`, `depends_on.condition: service_completed_successfully`, `deploy.mode: replicated-job`, `deploy.mode: global-job`, external/content/environment-backed service `configs` and `secrets`, service `restart`, and `deploy.restart_policy`.
- **Missing apple/container primitive:** Health status, exit code/completion-time metadata, Compose-compatible job lifecycle and scheduler semantics, first-class config/secret store or materialization primitives, ownership/mode controls for non-file-backed grants, and restart policy support.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A4](#a4-apple-gap-health-config-and-secret-stores-and-restart).

#### Compose model runner

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** Top-level `models`, service `models`, `endpoint_var`, `model_var`, `context_size`, and `runtime_flags`.
- **Missing apple/container primitive:** Compose-compatible model runner lifecycle, model pull/configure operations, endpoint discovery, and an endpoint URL that is reachable from apple/container service containers. Docker Compose implements this through the Docker Model plugin; apple/container does not expose an equivalent primitive yet.
- **container-compose status:** `config` and `convert` preserve top-level model definitions and service model binding metadata. Runtime commands reject service model bindings before resources are created.
- **Example:** [A11](#a11-apple-gap-compose-model-runner).

#### Start-first service replacement

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** `deploy.update_config.order: start-first` and any future update order that requires more than the local stop-first recreate boundary.
- **Missing apple/container primitive:** A Docker Compose compatible replacement handoff: create a temporary replacement while the old service container is still running, then either rename the replacement to the stable Compose container identity or move the service hostname/alias to it after the old container is removed. Current apple/container APIs expose create, stop, and delete, but no container rename or service-alias handoff, and container creation rejects duplicate container IDs and duplicate attachment hostnames. Unknown update orders are rejected as apple/container update-orchestration gaps rather than plugin backlog.
- **container-compose status:** Rejected before resources are created with a precise apple/container runtime-gap message.
- **Example:** [A12](#a12-apple-gap-start-first-service-replacement).

#### Advanced build configuration

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** `additional_contexts`, `entitlements`, build `extra_hosts`, build `isolation`, build `network`, build `privileged`, `provenance`, `sbom`, unsupported build secret forms and metadata, build `shm_size`, `ssh`, and build `ulimits`.
- **Missing apple/container primitive:** Docker Compose compatible BuildKit inputs for additional contexts, build host entries, build network modes, isolation, privileged builds, entitlements, SSH forwarding, advanced build secret metadata, build shared memory, build ulimits, and provenance/SBOM attestations.
- **container-compose status:** Rejected before `container build` is invoked.
- **Example:** [A6](#a6-apple-gap-advanced-build-fields).

#### Advanced mounts and storage controls

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** Long-form service `volume.subpath`, image-backed service mounts, `image.subpath`, advanced bind/volume options such as bind propagation, SELinux flags, recursive bind behavior, mount consistency, non-local service `volume_driver`, service `storage_opt`, and external inherited block mounts.
- **Missing apple/container primitive:** Named-volume subpath mounts, image-backed service mounts, advanced bind/volume controls, non-local service volume drivers, per-container root filesystem storage options, and a Compose-compatible way to inherit external block mounts. The current apple/container CLI/API mount surface exposes volume source, target, readonly, tmpfs size, and tmpfs mode, but no subpath, image mount source selector, propagation/SELinux/consistency controls, block-mount inheritance mapping, or service storage option mapping.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A8](#a8-apple-gap-advanced-mounts-and-storage-controls).

#### Service logging controls

- **Status:** <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">
- **Compose surface:** Service `logging`, `log_driver`, and `log_opt`.
- **Missing apple/container primitive:** Compose-compatible remote service logging drivers, log metadata controls, released line-correct server-side replay filters across all log record sources, and a rotation-aware follow cursor or stream. Current released apple/container log APIs expose runtime log streams but not per-service logging driver/option configuration. The local integration stack treats `--log-driver json-file` and `--log-driver local` as local capture aliases, adds disabled persisted capture through `--log-driver none`, parses local `--log-opt max-size=<size>` and `--log-opt max-file=<count>`, has writer-level local rotation when a runtime logging policy supplies max size and file count, and exposes static rotated raw and structured replay.
- **container-compose status:** Accepts file-backed `json-file` and `local` logging as mappings to apple/container's local stdio log capture. On the local integration stack, `logging.driver: none` and legacy `log_driver: none` map to disabled persisted capture. Local `logging.options` and legacy `log_opt` values for `max-size` and `max-file` map to apple/container `--log-opt` flags for the default, `json-file`, and `local` drivers. Static `logs` / `logs --timestamps` requests include rotated files when apple/container supports them. Followed structured logs use active record-file follow; raw rotation-aware follow remains plugin-side experimental until apple/container exposes a cursor or stream primitive. Remote drivers, non-local logging options, and options attached to `none` remain rejected until apple/container exposes the required runtime primitives.
- **Example:** [A10](#a10-partial-service-logging-controls).

#### API socket and block I/O controls

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** `use_api_socket` and `blkio_config`.
- **Missing apple/container primitive:** A safe Docker-compatible or apple/container-compatible API socket boundary with credential handoff and least-privilege controls, plus block I/O resource controls for blkio weight and read/write throttling. apple/container can mount Unix sockets and report block I/O stats, but it does not expose the Docker Compose API-socket or blkio resource-control behavior that these fields require.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A13](#a13-apple-gap-api-socket-and-block-io).

#### Runtime data commands

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** `top`, `events`, `pause`, `unpause`, already-stopped `wait` exit-code replay, `cp --archive`, and `cp --follow-link`.
- **Missing apple/container primitive:** Process listing, event stream, pause/unpause, stored process exit codes after container stop, and copy archive/follow-link controls.
- **container-compose status:** Rejected before resources are created.
- **Example:** [A5](#a5-apple-gap-runtime-data-commands).

#### Interactive init-process attach and foreground hook boundaries

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** Default stdin/signal-proxy `attach`, `attach --sig-proxy=true`, `attach --detach-keys`, attached `up` with service `post_start`, foreground one-off `run` with service `post_start`, and foreground one-off `run` with service `pre_stop`.
- **Missing apple/container primitive:** Reattaching stdin/stdout/stderr to an already-running init process, signal proxying to that process, detach-key handling, and an interceptable foreground one-off stop boundary. apple/container can wire stdio while bootstrapping a container or creating a new exec process, but it does not expose a Compose-compatible path that starts the init process, lets `container-compose` run lifecycle hooks, then reattaches to the same init process before it exits.
- **container-compose status:** Output-only `attach --no-stdin --sig-proxy=false` is supported through log streaming. Default interactive attach rejects before side effects with a precise apple/container runtime-gap message.
- **Example:** [A9](#a9-apple-gap-interactive-attach).

#### Image commit and Compose application publishing

- **Status:** <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">
- **Compose surface:** `commit`, `publish`, and `oci://` Compose application references.
- **Missing apple/container primitive:** Container-to-image commit snapshots with image metadata, plus Compose application OCI artifact publishing and consumption.
- **container-compose status:** Command names are exposed so Docker Compose v2 scripts get precise unsupported-feature errors instead of unknown-command failures.
- **Example:** [A7](#a7-apple-gap-image-commit-and-compose-publish).

### Blocked By `container-compose`

Status: <img alt="NO PLUGIN GAP" src="https://img.shields.io/badge/NO%20PLUGIN%20GAP-2E7D32?style=flat-square">

No remaining runtime surface-level gaps are currently classified here. Mixed examples below still capture areas where plugin work was completed alongside apple/container runtime boundaries, but the open unsupported runtime surfaces are now tracked under the first missing apple/container primitive.

### Config-Only Today

These Compose surfaces are useful in normalized output, but they do not currently change runtime orchestration.

#### Top-level and service `x-*` extensions

- **Status:** <img alt="CONFIG ONLY" src="https://img.shields.io/badge/CONFIG%20ONLY-6B7280?style=flat-square">
- **Current behavior:** Preserved by `container compose config` and `container compose convert`; no runtime behavior by itself.
- **Example:** [O1](#o1-config-only-metadata).

#### Service `expose`

- **Status:** <img alt="CONFIG ONLY" src="https://img.shields.io/badge/CONFIG%20ONLY-6B7280?style=flat-square">
- **Current behavior:** Preserved by `config` and `convert`; it does not publish host ports. Use `ports` for host publishing.
- **Example:** [O1](#o1-config-only-metadata).

#### Top-level `configs` and `secrets` definitions

- **Status:** <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square">
- **Current behavior:** Preserved by `config` and `convert`. File-backed definitions can feed service `configs` and `secrets` through read-only runtime bind mounts. File-backed and environment-backed secrets can feed supported `build.secrets`.
- **Runtime boundary:** External definitions, inline `content`, environment-backed runtime grants, and strict `uid`/`gid`/`mode` materialization need first-class [`apple/container`][apple-container] config/secret store or materialization primitives.
- **Examples:** [S1](#s1-supported-local-web-stack), [O1](#o1-config-only-metadata), [A4](#a4-apple-gap-health-config-and-secret-stores-and-restart).

#### Top-level `models` definitions

- **Status:** <img alt="CONFIG ONLY" src="https://img.shields.io/badge/CONFIG%20ONLY-6B7280?style=flat-square">
- **Current behavior:** Preserved by `config` and `convert`.
- **Runtime boundary:** Service-level model bindings are an [`apple/container`][apple-container] model-runner gap.
- **Examples:** [O1](#o1-config-only-metadata), [A11](#a11-apple-gap-compose-model-runner).

## CLI Command Status

### Supported Commands

Status: <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square">

- Config and project: `config`, `convert`, and `ls`.
- Lifecycle: `create`, `up`, `scale`, `down`, `run`, `start`, `stop`, `restart`, `rm`, `kill`, and running/stopping-container `wait`.
- Build and image: `build`, `pull`, `push`, `images`, and `down --rmi`.
- Interaction: `ps`, `logs`, output-only `attach --no-stdin --sig-proxy=false`, `exec`, `cp`, `export`, published-port `port`, `stats`, `stats --no-trunc`, and `version`.
- Develop: `watch`, `watch --dry-run`, `watch --no-up`, `watch --no-prune`, and `watch --quiet`.
- Provider services: provider-backed `up`, one-off `run` dependency startup, `down`, and advertised `stop`.
- Supported option families include indexed service targets, quiet/json/table output where listed above, explicit, target-only dynamically allocated, and host-bound published ports, `--scale`, `--timeout`, `--no-build`, `--quiet-build`, `--quiet-pull`, `--no-start`, `--always-recreate-deps`, `--include-deps`, `--ignore-buildable`, `--ignore-pull-failures`, `--ignore-push-failures`, and `--down-project` for running/stopping service containers.

### Commands Blocked By [`apple/container`][apple-container] Runtime Gaps

Status: <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square">

- `top`, `events`, `pause`, and `unpause`.
- Already-stopped `wait` exit-code replay.
- `cp --archive` and `cp --follow-link`.
- Default interactive `attach`, including stdin forwarding, signal proxying, and detach-key handling.
- `commit` container image snapshots.
- `publish` Compose application OCI artifacts and `oci://` Compose file consumption.

### Commands Blocked By `container-compose` Design Gaps

Status: <img alt="NO PLUGIN GAP" src="https://img.shields.io/badge/NO%20PLUGIN%20GAP-2E7D32?style=flat-square">

- No remaining command-level gaps are currently classified here. Plugin-owned orchestration gaps are tracked in the compatibility sections above.

## References

- Compose file reference: [docs.docker.com/reference/compose-file](https://docs.docker.com/reference/compose-file/).
- Docker Compose v2 CLI reference: [docs.docker.com/reference/cli/docker/compose](https://docs.docker.com/reference/cli/docker/compose/).
- Docker Compose v2 implementation: [`docker/compose`](https://github.com/docker/compose).
- Docker Compose v2 Go API package: [`github.com/docker/compose/v2/pkg/api`](https://pkg.go.dev/github.com/docker/compose/v2/pkg/api).
- Compose model normalizer used here: [`compose-spec/compose-go`](https://github.com/compose-spec/compose-go).
- apple/container public documentation: [apple.github.io/container/documentation](https://apple.github.io/container/documentation/).
- Apple `ContainerClient` API documentation for direct Swift runtime adapter work: [apple.github.io/container/documentation/containerclient](https://apple.github.io/container/documentation/containerclient/).

## Example Index

Every example includes a Compose file or commands plus the matching Dockerfile snippets needed to try the surface in an isolated scratch directory.

- <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> [S1: Supported Local Web Stack](#s1-supported-local-web-stack): Demonstrates build, images, `create`, ports, static `port`, environment, one network, no-network services, single-network MAC addresses, volume mounts, file-backed service configs/secrets, `volumes`, labels, `label_file`, lifecycle, logs, exec, stats, copy, and `down --volumes`.
- <img alt="SUPPORTED" src="https://img.shields.io/badge/SUPPORTED-2E7D32?style=flat-square"> [S2: Supported Provider Service](#s2-supported-provider-service): Demonstrates provider lifecycle commands and provider `setenv` injection into dependent services.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A1: Apple Gap, Networking](#a1-apple-gap-networking): Demonstrates multiple networks, aliases, service-name DNS for replicas, deploy endpoint modes, fixed IP attachment options, network namespace modes other than no-network, and IPAM controls beyond one IPv4/IPv6 subnet.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A2: Apple Gap, Host Identity And Links](#a2-apple-gap-host-identity-and-links): Demonstrates hostname, domain name, explicit host entries, and legacy links.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A3: Apple Gap, Runtime Controls](#a3-apple-gap-runtime-controls): Demonstrates namespace controls, privileged/device access, resource controls beyond the supported local limits, and sysctls.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A4: Apple Gap, Health, Config And Secret Stores, And Restart](#a4-apple-gap-health-config-and-secret-stores-and-restart): Demonstrates healthchecks, healthy/completed dependency gates, deploy job modes, external/content/environment-backed service secrets/configs, and restart policies.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A5: Apple Gap, Runtime Data Commands](#a5-apple-gap-runtime-data-commands): Demonstrates process listing, event streams, pause/unpause, already-stopped exit-code replay, and copy archive/follow-link controls.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A6: Apple Gap, Advanced Build Fields](#a6-apple-gap-advanced-build-fields): Demonstrates additional contexts, unsupported secret forms and metadata, SSH forwarding, and provenance/SBOM fields.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A7: Apple Gap, Image Commit And Compose Publish](#a7-apple-gap-image-commit-and-compose-publish): Demonstrates service-container image commit and Compose application OCI artifact publishing.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A8: Apple Gap, Advanced Mounts And Storage Controls](#a8-apple-gap-advanced-mounts-and-storage-controls): Demonstrates named-volume subpaths, image-backed service mounts, advanced bind options, non-local service volume drivers, and service storage options.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A9: Apple Gap, Interactive Attach](#a9-apple-gap-interactive-attach): Demonstrates default interactive attach behavior and foreground lifecycle hook ordering that need runtime reattach or stop-boundary primitives.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> [A10: Partial, Service Logging Controls](#a10-partial-service-logging-controls): Demonstrates accepted local file-backed logging and remaining service logging driver/option gaps.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A11: Apple Gap, Compose Model Runner](#a11-apple-gap-compose-model-runner): Demonstrates Compose model definitions and service model bindings that need a model-runner backend.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A12: Apple Gap, Start-First Service Replacement](#a12-apple-gap-start-first-service-replacement): Demonstrates `deploy.update_config.order: start-first`, which needs a temporary replacement handoff through container rename or service alias movement.
- <img alt="APPLE GAP" src="https://img.shields.io/badge/APPLE%20GAP-C62828?style=flat-square"> [A13: Apple Gap, API Socket And Block I/O](#a13-apple-gap-api-socket-and-block-io): Demonstrates Docker-compatible API socket exposure and block I/O controls after supported volume inheritance is accepted.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> [C1: Replica Scaling And Deploy Metadata](#c1-replica-scaling-and-deploy-metadata): Demonstrates supported scale forms, collision safeguards, local deploy metadata, and remaining [`apple/container`][apple-container] deploy/runtime gaps.
- <img alt="PARTIAL" src="https://img.shields.io/badge/PARTIAL-B26A00?style=flat-square"> [C3: Partial, Develop, Providers, And Hooks](#c3-partial-develop-providers-and-hooks): Demonstrates supported watch/develop, supported providers, supported detached lifecycle hooks, and foreground hook apple/container gaps.
- <img alt="CONFIG ONLY" src="https://img.shields.io/badge/CONFIG%20ONLY-6B7280?style=flat-square"> [O1: Config-Only Metadata](#o1-config-only-metadata): Demonstrates extension metadata, top-level models/secrets, and `expose` in normalized output.

## Examples With Dockerfiles

### S1: Supported Local Web Stack

Expected result: `container compose config`, `container compose convert`, `build --pull --with-dependencies --quiet`, `build --push`, `pull --include-deps --policy missing --quiet`, `push --include-deps --quiet`, `create`, `create --quiet-pull`, `up`, `up --quiet-build`, `up --quiet-pull`, `up --always-recreate-deps`, `up --timeout`, file-backed runtime configs/secrets, service `attach: false`, `ps`, `logs`, timestamped and time-filtered logs on the local structured-record integration stack, `exec`, `stats`, `wait` and `wait --down-project` for running/stopping service containers, `cp`, `volumes`, `rm --force --volumes` for anonymous volumes, and `down --volumes` run through [`apple/container`][apple-container].

Status path:

- Docker Compose v2: accepts and normalizes this project.
- [`apple/container`][apple-container]: has the needed build, image, lifecycle, discovery, network, volume, read-only bind mount, log, exec, wait, copy, and export primitives.
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
    logging:
      driver: json-file
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
    configs:
      - source: api_config
        target: /etc/api.conf
    secrets:
      - api_token
    volume_driver: local
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

configs:
  api_config:
    file: ./api.conf

secrets:
  api_token:
    file: ./api-token.txt
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

File: `api.conf`

```text
enabled=true
```

File: `api-token.txt`

```text
local-runtime-secret-placeholder
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
container compose logs
container compose logs --index 2 api
container compose logs --since 2026-06-18T10:00:00Z --until 30m api
container compose logs --since 1781776800 --until 1781782200.25 api
container compose logs --follow --timestamps api
container compose logs --follow --since 2026-06-18T10:00:00Z --until 30m api
container compose --ansi always logs api
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

### S2: Supported Provider Service

Expected result: `container compose up api` runs the provider `compose metadata` and `compose up` commands for `database`, injects returned `setenv` values into the dependent `api` service as `DATABASE_<KEY>` environment variables, and then starts `api` through [`apple/container`][apple-container]. `container compose run api env` starts provider dependencies before the one-off service and injects the same variables into the one-off environment. `container compose stop database` invokes provider `compose stop` only when metadata advertises it. `container compose down` invokes provider `compose down` for provider-backed services.

Status path:

- Docker Compose v2: accepts and normalizes provider services and the provider JSON-message protocol.
- [`apple/container`][apple-container]: no runtime primitive is needed for the provider process itself; dependent service containers use ordinary environment-variable support.
- `container-compose`: maps provider lifecycle commands, metadata validation, option filtering, and provider `setenv` injection for direct dependents.

```yaml
# compose.yaml
name: provider-demo

services:
  api:
    build:
      context: ./api
    depends_on:
      database:
        condition: service_started
    command: ["sh", "-c", "printf '%s\n' \"$DATABASE_URL\" && sleep 3600"]

  database:
    provider:
      type: ./providers/example-db
      options:
        name: local-db
        size: small
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "env | sort && sleep 3600"]
```

File: `providers/example-db`

```sh
#!/bin/sh
if [ "$1" != "compose" ]; then
    printf '{"type":"error","message":"expected compose subcommand"}\n'
    exit 1
fi

case "$2" in
metadata)
    printf '{"description":"example provider","up":{"parameters":[{"name":"name","required":true},{"name":"size"}]},"down":{"parameters":[{"name":"name","required":true}]},"stop":{"parameters":[{"name":"name","required":true}]}}\n'
    ;;
up)
    printf '{"type":"info","message":"database ready"}\n'
    printf '{"type":"setenv","message":"URL=postgres://local-db.example/provider"}\n'
    ;;
down|stop)
    printf '{"type":"info","message":"database %s complete"}\n' "$2"
    ;;
*)
    printf '{"type":"error","message":"unsupported provider command"}\n'
    exit 1
    ;;
esac
```

Useful supported commands against this project:

```sh
chmod +x providers/example-db
container compose config
container compose up api
container compose run api env
container compose stop database
container compose down
```

### A1: Apple Gap, Networking

Expected result: `container compose up` rejects this before creating resources because [`apple/container`][apple-container] needs multi-network attach/connect, per-network aliases/options beyond MAC and MTU, VIP/DNSRR endpoint discovery, service-name DNS that can return multiple replica addresses, fixed addresses, network namespace modes other than no-network, and IPAM controls beyond one IPv4/IPv6 subnet.

Status path:

- Docker Compose v2: accepts and normalizes these network attachments.
- [`apple/container`][apple-container]: missing multi-network attach/connect, per-network aliases/options beyond MAC and MTU, service-name aliases, VIP/DNSRR endpoint discovery, multi-record DNS lookup for scaled replicas, fixed addresses, Docker-compatible namespace modes other than no-network, IPAM gateway/range/auxiliary-address controls, custom IPAM drivers, and multiple same-family IPAM subnets.
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
      endpoint_mode: dnsrr
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
- `container-compose`: detects those fields and reports the apple/container runtime gap.

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

Expected result: `container compose up` rejects this because [`apple/container`][apple-container] needs namespace, resource controls beyond the supported local CPU/memory/ulimit subset, deploy resource reservation guarantees, privileged/device, and sysctl primitives. `container compose exec --privileged` is rejected because privileged exec processes need an [`apple/container`][apple-container] primitive.

Status path:

- Docker Compose v2: accepts and normalizes these runtime controls.
- [`apple/container`][apple-container]: missing the required namespace, privileged/device, resource controls beyond supported `cpus`, `mem_limit`, `shm_size`, and `ulimits`, deploy PID-limit and reservation primitives, sysctl, and privileged exec primitives.
- `container-compose`: detects those fields and reports the apple/container runtime gap.

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
    deploy:
      resources:
        limits:
          pids: 128
        reservations:
          cpus: "0.5"
          memory: 128m
    sysctls:
      net.ipv4.ip_local_port_range: "1024 65000"
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "sleep 3600"]
```

### A4: Apple Gap, Health, Config And Secret Stores, And Restart

Expected result: `container compose up` rejects this because [`apple/container`][apple-container] needs health status, completion metadata, job lifecycle/scheduler semantics, first-class config/secret stores or materialization, and restart policies for both service `restart` and `deploy.restart_policy`. File-backed service configs/secrets are supported in [S1](#s1-supported-local-web-stack); this example uses inline and external definitions to show the remaining runtime store gap.

Status path:

- Docker Compose v2: accepts and normalizes healthchecks, dependency conditions, configs, secrets, service restart policies, deploy restart policies, and deploy job modes.
- [`apple/container`][apple-container]: missing health status, exit/completion metadata, job lifecycle/scheduler semantics, first-class config/secret store or materialization primitives, and restart policy support.
- `container-compose`: detects those fields and reports the apple/container runtime gap.

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
    deploy:
      restart_policy:
        condition: on-failure
        max_attempts: 3
    depends_on:
      api:
        condition: service_healthy

  batch:
    build:
      context: ./batch
    command: ["sh", "-c", "printf 'done\n'"]
    deploy:
      mode: replicated-job
      replicas: 2

configs:
  api_config:
    content: |
      enabled=true

secrets:
  api_token:
    external: true
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

Dockerfile: `batch/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "printf 'done\n'"]
```

### A5: Apple Gap, Runtime Data Commands

Expected result: these commands and options reject because [`apple/container`][apple-container] needs richer runtime data and state controls. `container compose port` supports published bindings from runtime container snapshots, including explicit ranges, dynamically allocated ports after container creation, and indexed existing service containers. Plain service-aware `container compose cp` is supported, but `cp --archive` and `cp --follow-link` reject until [`apple/container`][apple-container] exposes copy archive and symlink-follow controls. `container compose wait` and `container compose wait --down-project` can wait for running or stopping service containers, but replaying exit codes for containers that were already stopped before the command starts still needs stored exit-code metadata from [`apple/container`][apple-container].

Status path:

- Docker Compose v2: supports these commands.
- [`apple/container`][apple-container]: missing process listing, event streaming, pause/unpause, stored exit-code metadata for already-stopped containers, and copy archive/follow-link controls.
- `container-compose`: exposes the command names, resolves published-port lookups from runtime snapshots, supports indexed target lookup for existing Compose-managed service containers, supports plugin-side dynamic host-port allocation, including `host_ip` bindings, before calling apple/container with explicit publish bindings, supports `stats --all` by combining direct stats for running containers with stopped-container metadata from project discovery, supports `stats --no-trunc` because the direct renderer already emits full container IDs, supports `wait` and `wait --down-project` for running/stopping service containers, and reports the apple/container runtime gap for requests that need unavailable runtime state.

```yaml
# compose.yaml
name: apple-command-gap-demo

services:
  api:
    build:
      context: ./api
    ports:
      - "8080:8080"

  worker:
    build:
      context: ./worker
```

Run:

```sh
container compose top api
container compose events --json
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

### C1: Replica Scaling And Deploy Metadata

Expected result: `container compose up` accepts simple local replica counts for services that can be safely duplicated, including `deploy.mode: replicated`, local no-op `deploy.mode: global`, `deploy.labels` service metadata, local stop-first `deploy.update_config` with `delay`, Docker Compose local no-op update metadata, `deploy.rollback_config`, `deploy.placement`, services with explicit host port ranges large enough to allocate one deterministic slice per replica, and services with anonymous volumes that can be named per replica. Scaled services reject before side effects when a Compose file would create duplicate runtime names, duplicate fixed published ports, or duplicate fixed MAC addresses. Deploy job modes are tracked in [A4](#a4-apple-gap-health-config-and-secret-stores-and-restart), and start-first service replacement is tracked in [A12](#a12-apple-gap-start-first-service-replacement).

Status path:

- Docker Compose v2: accepts and normalizes scaling and deploy metadata.
- [`apple/container`][apple-container]: supports the lifecycle and resource primitives needed for these local scale forms, while scaled service-name DNS is tracked in [A1](#a1-apple-gap-networking).
- `container-compose`: maps standalone `scale`, `up --scale`, `create --scale`, service `scale`, `deploy.mode: replicated`, and local `deploy.replicas` to indexed containers; accepts `deploy.mode: global` as Docker Compose local no-op metadata because local Compose convergence uses `scale` / `deploy.replicas` rather than deployment mode; rejects `deploy.mode: replicated-job`, `deploy.mode: global-job`, and unknown deploy modes as apple/container job lifecycle or scheduler gaps; preserves `deploy.labels` as service metadata without applying them as container labels; accepts `deploy.update_config.order: stop-first` and `deploy.update_config.delay` because the orchestrator recreates local replicas one at a time with a stop-before-start boundary; accepts Docker Compose local no-op deploy metadata such as `deploy.update_config.parallelism`, `deploy.update_config.failure_action`, `deploy.update_config.monitor`, `deploy.update_config.max_failure_ratio`, `deploy.rollback_config`, and `deploy.placement`; maps large enough published-port ranges to deterministic per-replica host ports; maps anonymous volumes to deterministic per-replica runtime volume names; maps `deploy.resources.limits.cpus` and `deploy.resources.limits.memory` to local runtime limits; reports apple/container resource gaps for `deploy.resources.limits.pids`, `deploy.resources.limits.devices`, `deploy.resources.limits.generic_resources`, `deploy.resources.reservations`, `deploy.update_config.order: start-first`, and unknown update orders; can target indexed service containers for `logs`, `attach`, `exec`, `cp`, `export`, and `port`; and rejects scaled `container_name`, too-small published-port ranges, and fixed MAC addresses before creating resources.

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
      mode: replicated
      labels:
        com.example.service: worker
      replicas: 3
      update_config:
        parallelism: 2
        order: stop-first
        delay: 2s
        failure_action: pause
        monitor: 15s
        max_failure_ratio: 0.3
      rollback_config:
        parallelism: 2
        order: stop-first
        failure_action: pause
        monitor: 15s
      placement:
        constraints:
          - node.role == worker
        preferences:
          - spread: node.labels.zone
        max_replicas_per_node: 1

  global-worker:
    image: alpine:3.20
    deploy:
      mode: global
      labels:
        com.example.service: global-worker

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

Expected result: `container compose commit` and `container compose publish` are recognized command names, then reject with apple/container runtime-gap messages. Existing apple/container image primitives such as image save, tag, push, and container export are useful adjacent operations, but they do not create a new image from a service container's changed filesystem or package a Compose application as an OCI artifact that can be consumed with `oci://`.

Status path:

- Docker Compose v2: supports service-container image commits and Compose application publishing.
- [`apple/container`][apple-container]: missing a container commit image-snapshot primitive and Compose application OCI artifact publish/consume primitives.
- `container-compose`: exposes the command names and reports the apple/container runtime boundary precisely.

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

### A8: Apple Gap, Advanced Mounts And Storage Controls

Expected result: `container compose up` rejects this before creating resources because apple/container does not expose mount/storage primitives for selecting a subpath inside a named volume, mounting filesystem content from an image, applying advanced bind options, using a non-local service volume driver, or setting per-container storage options.

Status path:

- Docker Compose v2: accepts and normalizes advanced service mount and storage metadata.
- [`apple/container`][apple-container]: supports named volume mounts, bind mounts, tmpfs mounts, readonly mounts, tmpfs `size`, and tmpfs `mode`, but not named-volume subpath mounts, image-backed service mounts, bind propagation/SELinux/consistency controls, non-local service volume drivers, or service `storage_opt`.
- `container-compose`: reports the apple/container mount primitive gap before resources are created.

```yaml
# compose.yaml
name: apple-advanced-mount-gap-demo

services:
  api:
    build:
      context: ./api
    volume_driver: nfs
    storage_opt:
      size: 1G
    volumes:
      - type: bind
        source: ./config
        target: /config
        bind:
          propagation: shared
      - type: volume
        source: shared-data
        target: /data
        volume:
          subpath: api
      - type: image
        source: alpine:3.20
        target: /image-root
        image:
          subpath: etc

volumes:
  shared-data: {}
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
RUN mkdir -p /app
CMD ["sh", "-c", "sleep 3600"]
```

File: `config/example.txt`

```text
local config placeholder
```

### C3: Partial, Develop, Providers, And Hooks

Expected result: `container compose config` preserves the `develop.watch`, `provider`, `post_start`, and `pre_stop` metadata. `container compose --dry-run watch api` validates service selection and trigger shape before printing the planned watch settings/actions, and live `container compose watch api` polls local files before executing sync, sync+restart, sync+exec, restart, and rebuild actions. `container compose up` treats `develop.watch` as harmless metadata and supports provider-backed dependencies as shown in [S2](#s2-supported-provider-service). Detached service lifecycle paths and detached one-off `run` execute supported `post_start` hooks through direct exec, and service-aware stops execute supported `pre_stop` hooks before stopping containers. Detached one-off containers also execute `pre_stop` when `container-compose` later stops them through project cleanup. Attached `up` or foreground `run` with lifecycle hooks reject clearly until apple/container exposes the foreground attach and stop-boundary primitives tracked in [A9](#a9-apple-gap-interactive-attach).

Status path:

- Docker Compose v2: accepts and normalizes develop, provider, and hook fields.
- [`apple/container`][apple-container]: direct exec supports the detached hook paths; foreground hook ordering needs the reattach or stop-boundary primitive tracked in [A9](#a9-apple-gap-interactive-attach).
- `container-compose`: preserves normalized `develop.watch`, `provider`, `post_start`, and `pre_stop` metadata; validates `watch` command selections; emits a dry-run watch plan; supports live polling watch execution through direct copy, exec, restart, build, and image prune paths; executes provider service `up`, `down`, and advertised `stop`; executes service lifecycle hooks for detached service starts, `start`, `stop`, `restart`, `down`, recreation, and replica pruning; executes `post_start` for detached one-off `run`; and executes `pre_stop` before detached one-off cleanup.

```yaml
# compose.yaml
name: partial-extension-demo

services:
  api:
    build:
      context: ./api
    depends_on:
      database:
        condition: service_started
    post_start:
      - command: ["sh", "-c", "echo started"]
    pre_stop:
      - command: ["sh", "-c", "echo stopping"]
    develop:
      watch:
        - path: ./api/src
          target: /app/src
          action: sync

  database:
    provider:
      type: ./providers/example-db
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
container compose up --detach api
container compose restart api
container compose run --detach api
container compose --dry-run watch --no-up --no-prune --quiet api
container compose watch --no-up --no-prune --quiet api
```

### A13: Apple Gap, API Socket And Block I/O

Expected result: `container compose up` accepts same-project `volumes_from`, external `volumes_from` backed by apple/container volume/bind/tmpfs mount metadata, `volume_driver: local`, and `volume.nocopy` as supported storage behavior. This example then rejects because Docker-compatible API socket exposure and block I/O resource controls need apple/container runtime primitives. Logging driver/options are tracked in [A10](#a10-partial-service-logging-controls), while advanced mount and storage controls are tracked in [A8](#a8-apple-gap-advanced-mounts-and-storage-controls).

Status path:

- Docker Compose v2: accepts and normalizes these service fields.
- [`apple/container`][apple-container]: can mount Unix sockets and report block I/O stats, but it does not expose a Docker-compatible API socket and credential handoff for `use_api_socket` or create/run resource controls for `blkio_config` weight and throttling.
- `container-compose`: maps service `pull_policy: daily`, `weekly`, and `every_<duration>` through direct image pulls and local pull timestamp metadata, maps service `pull_policy: build` through the existing build path, maps service annotations to apple/container runtime metadata labels, maps same-project service `volumes_from` for declared Compose mounts, maps external `volumes_from` by inspecting the referenced container through direct apple/container APIs, accepts `volume_driver: local`, accepts `volume.nocopy` as no-copy behavior already matched by the apple/container volume mount path, and maps long-form tmpfs `size`/`mode` through `container --mount type=tmpfs`. It rejects `use_api_socket` and `blkio_config` before resources are created with precise apple/container runtime-gap messages.

The external container reference assumes an existing apple/container container named `legacy-worker` with volume, bind, or tmpfs mounts that can be represented as `container --volume` or `--mount type=tmpfs` arguments.

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
    volume_driver: local
    volumes_from:
      - base:ro
      - container:legacy-worker:ro
    volumes:
      - type: volume
        source: shared-data
        target: /data
        volume:
          nocopy: true
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

### A9: Apple Gap, Interactive Attach

Expected result: output-only `container compose attach --no-stdin --sig-proxy=false` works through the runtime log stream. Default Docker Compose attach semantics reject because [`apple/container`][apple-container] does not expose stdin/stdout/stderr reattach, signal proxying, or detach-key handling for an already-running service container. Attached `up` or foreground one-off `run` with lifecycle hooks also reject clearly because the runtime cannot start the init process, let `container-compose` run hooks, and then reattach to that foreground process.

Status path:

- Docker Compose v2: supports default interactive attach behavior and foreground lifecycle hook ordering.
- [`apple/container`][apple-container]: log streaming is available for output-only attach, and stdio can be wired while bootstrapping a container or creating a new exec process. It does not expose a Compose-compatible reattach path for an already-running init process or an interceptable stop boundary for foreground one-off containers.
- `container-compose`: supports output-only attach and detached lifecycle-hook paths, then reports the apple/container runtime gap for default interactive attach and foreground hook ordering. `watch` command validation is tracked in [C3](#c3-partial-develop-providers-and-hooks), and `commit`/`publish` runtime gaps are tracked in [A7](#a7-apple-gap-image-commit-and-compose-publish).

```yaml
# compose.yaml
name: apple-attach-gap-demo

services:
  api:
    build:
      context: ./api
    image: example/api:dev
    post_start:
      - command: ["sh", "-c", "touch /tmp/ready"]
    pre_stop:
      - command: ["sh", "-c", "rm -f /tmp/ready"]

  worker:
    build:
      context: ./worker
```

Compare the supported and missing command behavior:

```sh
container compose attach --no-stdin --sig-proxy=false api
docker compose attach api
container compose up api
container compose run api sh -c 'echo foreground'
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

### A10: Partial, Service Logging Controls

Expected result: `container compose up api worker quiet rotated` accepts the file-backed `json-file` and `local` logging drivers, maps `none` to disabled persisted capture on the local integration stack, and maps `max-size`/`max-file` to apple/container local `--log-opt` flags. Static log replay can include rotated local raw and structured log files on the local integration stack. `container compose up shipper` rejects before creating resources because apple/container does not yet expose remote logging driver primitives.

Status path:

- Docker Compose v2: accepts and normalizes service logging configuration.
- [`apple/container`][apple-container]: exposes local runtime log streams. The local integration stack accepts `--log-driver json-file` and `--log-driver local` as local capture aliases, adds a disabled persisted-capture policy through `--log-driver none`, parses `--log-opt max-size=<size>` and `--log-opt max-file=<count>`, has writer-level local rotation when a runtime policy supplies max size and file count, stores structured records at Docker-like line boundaries, and exposes line-correct static rotated raw and structured replay. It still lacks remote drivers, driver-specific metadata controls, upstream-accepted replay/filter contracts, and an accepted rotation-aware follow cursor or stream.
- `container-compose`: accepts `json-file` and `local` as local log capture behavior, maps `none` to disabled persisted capture on the local integration stack, maps local `max-size`/`max-file` options to runtime `--log-opt` flags, requests static rotated replay for raw and timestamped logs, follows active structured record files, keeps plugin-side raw rotation-aware follow as an experimental validation path, then reports the remaining gap for remote drivers and runtime cursor/filter acceptance.

```yaml
# compose.yaml
name: apple-service-logging-gap-demo

services:
  api:
    build:
      context: ./api
    logging:
      driver: json-file

  worker:
    build:
      context: ./worker
    logging:
      driver: local

  quiet:
    build:
      context: ./quiet
    logging:
      driver: none

  rotated:
    build:
      context: ./rotated
    logging:
      driver: local
      options:
        max-size: "10m"
        max-file: "3"

  shipper:
    build:
      context: ./shipper
    log_driver: syslog
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

Dockerfile: `quiet/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo quiet; sleep 30; done"]
```

Dockerfile: `rotated/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo rotated; sleep 30; done"]
```

Dockerfile: `shipper/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "while true; do echo shipper; sleep 30; done"]
```

### A11: Apple Gap, Compose Model Runner

Expected result: `container compose config` preserves the top-level model definitions and service model binding metadata. Runtime commands such as `container compose up api` reject before creating resources because Docker Compose model support requires a model-runner backend that can pull/configure the model, report the model endpoint, and expose that endpoint to the service container.

Status path:

- Docker Compose v2: accepts and normalizes top-level `models`, service `models`, `endpoint_var`, `model_var`, `context_size`, and `runtime_flags`.
- [`apple/container`][apple-container]: does not expose a Compose-compatible model runner, model pull/configure lifecycle, endpoint discovery, or guaranteed service-container reachability for model-runner endpoints.
- `container-compose`: preserves normalized model definitions and service binding metadata for `config` and `convert`, then reports the apple/container runtime gap before resources are created.

```yaml
# compose.yaml
name: apple-model-runner-gap-demo

models:
  llm:
    model: ai/smollm2
    context_size: 4096
    runtime_flags:
      - "--no-prefill-assistant"

services:
  api:
    build:
      context: ./api
    models:
      llm:
        endpoint_var: MODEL_ENDPOINT
        model_var: MODEL_ID
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "env | sort && sleep 3600"]
```

### A12: Apple Gap, Start-First Service Replacement

Expected result: `container compose up api` rejects before creating resources because Docker Compose `deploy.update_config.order: start-first` replaces an existing service container by creating a temporary replacement while the old stable container still exists, then stopping/removing the old container and finalizing the replacement identity. apple/container currently has create, stop, and delete APIs, but no container rename or service hostname/alias handoff primitive for that finalization step.

Status path:

- Docker Compose v2: accepts and normalizes `deploy.update_config.order: start-first`, using a temporary replacement handoff for changed service containers.
- [`apple/container`][apple-container]: missing a Compose-compatible container rename or service-alias handoff primitive, and rejects duplicate container IDs and duplicate attachment hostnames during creation.
- `container-compose`: recognizes the normalized field and reports the apple/container runtime gap before resources are created.

```yaml
# compose.yaml
name: apple-start-first-gap-demo

services:
  api:
    build:
      context: ./api
    deploy:
      update_config:
        order: start-first
```

Dockerfile: `api/Dockerfile`

```dockerfile
FROM alpine:3.20
CMD ["sh", "-c", "date && sleep 3600"]
```

### O1: Config-Only Metadata

Expected result: `container compose config` preserves this metadata. Runtime commands do not publish `expose`, do not act on `x-*`, and reject service-level model bindings or config/secret grants only when they need unsupported runtime behavior such as a model runner or first-class config/secret store.

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
