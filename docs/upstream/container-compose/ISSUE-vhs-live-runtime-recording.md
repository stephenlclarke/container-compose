# Current VHS recording must show the volume-reuse lifecycle as live commands

## Problem

The mutable `current` release GIF replaced direct terminal commands with transcript replay after a terminal-recorder pseudo-terminal typed ahead of slow guest startup on an unsuitable runner. That made the artifact more reliable, but it no longer demonstrated commands being typed and their actual results. The recording must return to live commands on the hardware-virtualization-capable runner and gate each next step on the output from the current command.

The recording also needs to use the exact isolated `container` binary when Compose checks package compatibility. Without `CONTAINER_COMPOSE_CONTAINER`, the plugin can inspect an unrelated Homebrew runtime on the runner and reject a healthy packaged runtime.

The first direct-recording change also exposed an independent Source Checks defect: the
stack-consistency parser accepted only quoted SwiftPM revisions. The checked-out
Container manifest correctly uses its immutable `containerizationRevision` constant, so
the CI job rejected a valid stack before the release workflow could produce the corrected
GIF.

The first physical-runner attempt at the direct tape, from
[`d446560d`](https://github.com/stephenlclarke/container-compose/commit/d446560d5b9f34c46e4e135f3101f87486fa17da),
proved the fail-closed behaviour works: the cold runner was still fetching and
starting the first monitoring services after five minutes, so the chained
`ps` command had not yet emitted its table. The generic header wait therefore
timed out and prevented the stale recording from being replaced.

The next physical recording run reached the direct `container system start` command,
but its isolated root had to fetch the 569 MB Apple kernel. At the previous
90-second screen bound, the command was still live at 90% download and had not yet
printed `status running`; the fail-closed tape correctly stopped instead of
publishing an incomplete result.

The Current package queue may contain more than one virtualization-capable
self-hosted runner. One online runner repeatedly failed before checkout because it
could not establish TLS to GitHub's pinned action archive. A dedicated
`container-compose-current` capability label now routes the mutable recording to
the locally validated runner without changing the action pin or the tape.

That routed run proved the monitoring stack itself was healthy, but also found a
second screen-contract error: its real `ps` table renders the service name as
`alertmanager`, not a `monitoring-stack-…alertmanager` container name. The old
project-prefixed expression therefore could not match after a successful `up &&
ps`; the run was cancelled rather than wait out the remaining fifteen-minute
screen timeout.

The next direct attempt exposed two display and scope issues rather than an Apple
runtime fault. At the 1100-pixel recording width, the real `ps` status cell wraps
`running` across two screen rows, so a same-line regular expression cannot see it.
The complete monitoring file also contains services outside the two portable
demonstration endpoints; unqualified `stats` attempts to inspect those services
when they were intentionally not started. The direct, commit-matched runtime
lifecycle passed twice when restricted to nginx and Alertmanager, including both
HTTP readiness checks, retained named-volume reuse, stats, and final teardown.

The subsequent matched-package release run
[`29877513415`](https://github.com/stephenlclarke/container-compose/actions/runs/29877513415)
confirmed that both live `up && ps` checks now pass, then stopped at the first
live `stats` check. This runtime's actual table begins with `CONTAINER ID`, not
Docker's `NAME` heading; no generated or replayed output was involved. Commit
[`b6d9154e`](https://github.com/stephenlclarke/container-compose/commit/b6d9154e4584650a4923abb64bd50e2a5ee45153)
changes only the two tape screen assertions to that observed heading and adds
unit coverage that rejects the stale Docker-specific assertion.

The following matched-package release run
[`29878978449`](https://github.com/stephenlclarke/container-compose/actions/runs/29878978449)
proved that correction: both live `stats` tables, both HTTP readiness checks,
and the retained-volume marker write completed. It then failed closed at the
first `down --remove-orphans`: successful macOS Compose teardown prints only
its real `Loading Compose model` progress and no Docker-style `Removed` line.
Commit
[`1d8ff63f`](https://github.com/stephenlclarke/container-compose/commit/1d8ff63fb5f42f75a948a47dc36660296aa25ce4)
keeps `down` live and chains its successful completion to a real retained-volume
JSON listing; final teardown similarly chains to the real empty `ps --all`
result. It removes only the unsupported output assertion and adds a regression
test that rejects it.

## Scope and boundary

This is a `container-compose` release-automation correction. No Apple Container or Containerization primitive is missing: Container remains the authority for guest startup, volumes, and teardown; Compose owns the release demonstration policy.

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Existing guest and volume primitives. |
| `apple/container` | Existing macOS virtualization-backed runtime service. |
| `container-compose` | Matched-runtime selection, compatibility environment, direct fail-closed VHS recording, and release documentation. |

## Required change

- Use the hardware-virtualization-capable `container-compose-release` Apple-silicon runner for Current packages.
- Start and stop the clean, isolated matched runtime inside VHS so the published terminal session visibly contains the real lifecycle commands and their output.
- Set `CONTAINER_COMPOSE_CONTAINER` for every recorded Compose process so the plugin checks that isolated runtime rather than a host installation.
- Remove only the demo project before recording so the first `up` visibly starts services; retain project volumes with the intermediate `down --remove-orphans`.
- Record and fail on: first `up`, `stats`, `ps`, nginx health, Alertmanager readiness, a write to a marker in `nginx_cache`, retained-volume shutdown and a JSON listing that identifies the Compose-owned volume, second `up`, second `stats`/`ps`/health, a read of the same marker, and final `down --volumes --remove-orphans` plus empty `ps --all`.
- Render live command/output only. VHS must type each lifecycle command itself and wait for that command's real output; it must not replay transcript files or invoke marker helpers. Show both `up` commands, the persisted marker read, and final `down` at a readable pace so retained-volume reuse is unambiguous.
- Let the direct VHS session fail closed when a typed command fails or its required live output is absent; the job log is then the authoritative diagnostic artifact.
- Accept a named Swift manifest revision only when it resolves to a local string literal;
  reject dynamic or environment-derived values and continue to compare the result against
  `stack-refs.json` and `Package.resolved`.
- Keep the first and second `up --wait && ps` commands entirely live, but select
  the portable nginx and Alertmanager services for both `up` and `stats`. Give
  their cold-run waits a bounded fifteen-minute allowance. After the real `up`
  succeeds, clear the terminal and run the real `ps` command in the same typed
  shell chain so its actual result remains visible rather than scrollback. Match
  the nginx `running` cell across a possible screen-row wrap. Do not add a
  sentinel, replay, transcript, or marker-result command.
- Keep the first typed `container system start && container system status` command
  entirely live and give its cold-kernel screen wait the same bounded
  fifteen-minute allowance. Its actual `status running` output, not download
  progress, remains the only completion evidence.
- Require the dedicated `container-compose-current` self-hosted label in addition
  to the normal macOS, ARM64, and release labels. Assign it only to a runner that
  has successfully downloaded pinned GitHub actions over TLS.

## Commit tracking

- `fix(release): harden current demo recording`
- `fix(release): prove monitoring demo volume reuse`
- `fix(release): make volume reuse visible in demo` (`ac95e92b71270b37b2a3298bba86f50f16780a70`)
- [`62908819`](https://github.com/stephenlclarke/container-compose/commit/62908819034156bfc8d24cac7becce9a203d720b) `fix(release): record live VHS commands`
- [`518ae228`](https://github.com/stephenlclarke/container-compose/commit/518ae228f650a8fa40118c36d68fdad650eb69ef) `fix(release): record direct terminal demo`
- [`af6da141`](https://github.com/stephenlclarke/container-compose/commit/af6da14150d62f09fdadf6cf12d6aab6cde6b144) `fix(ci): validate named dependency revisions`
- [`0ed7efab`](https://github.com/stephenlclarke/container-compose/commit/0ed7efab0f85ced3c3e926ecd82c2cbccbc5ed57) `fix(release): wait for cold monitoring stack`
- [`2d8748c3`](https://github.com/stephenlclarke/container-compose/commit/2d8748c3) `fix(release): wait for cold kernel bootstrap`
- [`0c2c330f`](https://github.com/stephenlclarke/container-compose/commit/0c2c330f) `fix(release): dedicate current build runner`
- [`b09e3c79`](https://github.com/stephenlclarke/container-compose/commit/b09e3c79) `fix(release): match live compose status row`
- [`86dc033d`](https://github.com/stephenlclarke/container-compose/commit/86dc033d85d9c9c19817d4582dfa22cd92ba1022) `fix(release): keep live demo output visible`

## Code map

- `.github/workflows/prebuilt-binaries.yml` packages the matched runtime and plugin, exports the isolated runtime environment, validates the tape, and publishes the generated GIF. It does not start the system or create a transcript before recording.
- `.github/actionlint.yaml` declares the dedicated `container-compose-current`
  self-hosted capability so the workflow's MBP-only recording route is linted.
- `docs/container-compose-demo.tape` types the system start, every Compose and HTTP lifecycle command, the system stop, and their live output at a readable pace. It has no replay or marker helper. Its wider terminal preserves the real status table legibly.
- Its two `up --wait && clear && ps` steps select nginx and Alertmanager, then
  continue only after the real nginx `running` row from the just-typed `ps`
  command is visible. `clear` is a normal shell display command in the same
  failing shell chain, not a sentinel or a synthetic result.
- Its direct system-start step has that same bounded allowance and continues only
  after the just-typed command prints `status running`.
- `Tools/ci/check-stack-consistency.py` validates the Compose inline revision and the
  Container named literal revision without weakening the stack manifest or lockfile
  agreement checks.
- `examples/monitoring-stack/docker-compose.yaml` includes a portable `nginx_cache` named volume that visibly remains after the non-destructive down.

The tape and release-test validation run locally with VHS and the release workflow unit suite. The exact current Compose and Container sources also passed the full two-cycle lifecycle locally; the physical Apple-silicon release runner executes the published guest lifecycle.
