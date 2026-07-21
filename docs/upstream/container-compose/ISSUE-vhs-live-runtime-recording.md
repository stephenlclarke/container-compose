# Current VHS recording must show the volume-reuse lifecycle as live commands

## Problem

The mutable `current` release GIF replaced direct terminal commands with transcript replay after a terminal-recorder pseudo-terminal typed ahead of slow guest startup on an unsuitable runner. That made the artifact more reliable, but it no longer demonstrated commands being typed and their actual results. The recording must return to live commands on the hardware-virtualization-capable runner and gate each next step on the output from the current command.

The recording also needs to use the exact isolated `container` binary when Compose checks package compatibility. Without `CONTAINER_COMPOSE_CONTAINER`, the plugin can inspect an unrelated Homebrew runtime on the runner and reject a healthy packaged runtime.

## Scope and boundary

This is a `container-compose` release-automation correction. No Apple Container or Containerization primitive is missing: Container remains the authority for guest startup, volumes, and teardown; Compose owns the release demonstration policy.

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Existing guest and volume primitives. |
| `apple/container` | Existing macOS virtualization-backed runtime service. |
| `container-compose` | Matched-runtime selection, compatibility environment, fail-closed preflight, live VHS recording, and release documentation. |

## Required change

- Use the hardware-virtualization-capable `container-compose-release` Apple-silicon runner for Current packages.
- Start a clean, isolated matched runtime, execute the entire lifecycle once as a fail-closed preflight, then execute it again inside VHS as visible terminal commands.
- Set `CONTAINER_COMPOSE_CONTAINER` for every recorded Compose process so the plugin checks that isolated runtime rather than a host installation.
- Remove only the demo project before recording so the first `up` visibly starts services; retain project volumes with the intermediate `down --remove-orphans`.
- Record and fail on: first `up`, `stats`, `ps`, nginx health, Alertmanager readiness, a write to a marker in `nginx_cache`, retained-volume shutdown and a JSON listing that identifies the Compose-owned volume, second `up`, second `stats`/`ps`/health, a read of the same marker, and final `down --volumes --remove-orphans` plus empty `ps --all`.
- Render live command/output only. VHS must type each lifecycle command itself and wait for that command's real output; it must not replay transcript files or invoke marker helpers. Show both `up` commands, the persisted marker read, and final `down` at a readable pace so retained-volume reuse is unambiguous.
- Publish a partial transcript artifact on workflow failure and include the failed command output in the verifier error, so a release-runner failure is diagnosable without guessing from a red job summary.

## Commit tracking

- `fix(release): harden current demo recording`
- `fix(release): prove monitoring demo volume reuse`
- `fix(release): make volume reuse visible in demo` (`ac95e92b71270b37b2a3298bba86f50f16780a70`)
- [`62908819`](https://github.com/stephenlclarke/container-compose/commit/62908819034156bfc8d24cac7becce9a203d720b) `fix(release): record live VHS commands`

## Code map

- `Tools/release/record_monitoring_stack_transcript.py` is the narrow runtime boundary: it performs the fifteen-step verification cycle, writes and rereads a named-volume marker, records the retained volume as JSON before the reuse start, and includes captured output when a command fails. Its output is diagnostic preflight evidence, never tape input.
- `.github/workflows/prebuilt-binaries.yml` packages the matched runtime and plugin, executes that verifier, requires all fifteen logs, uploads a partial transcript on failure, validates the tape, and publishes the generated GIF.
- `docs/container-compose-demo.tape` presents the live lifecycle at a readable pace, including both shutdowns and the second startup's marker read.
- `examples/monitoring-stack/docker-compose.yaml` includes a portable `nginx_cache` named volume that visibly remains after the non-destructive down.

The tape and release-test validation passed locally with VHS 0.11.0 and 65 release tests.
