# Current VHS recording must verify the volume-reuse lifecycle before replay

## Problem

The mutable `current` release GIF previously tried to run Container guest lifecycle commands inside VHS. A terminal-recorder pseudo-terminal is not a dependable home for nested virtualization: a slow guest startup could make VHS type the next command early, and a hosted macOS runner cannot start the guest at all. The result was an intermittent Alertmanager bootstrap error and a demonstration that could not reliably prove a second `up` reuses retained Compose assets.

The recording also needs to use the exact isolated `container` binary when Compose checks package compatibility. Without `CONTAINER_COMPOSE_CONTAINER`, the plugin can inspect an unrelated Homebrew runtime on the runner and reject a healthy packaged runtime.

## Scope and boundary

This is a `container-compose` release-automation correction. No Apple Container or Containerization primitive is missing: Container remains the authority for guest startup, volumes, and teardown; Compose owns the release demonstration policy.

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Existing guest and volume primitives. |
| `apple/container` | Existing macOS virtualization-backed runtime service. |
| `container-compose` | Matched-runtime selection, compatibility environment, lifecycle transcript, VHS replay, and release documentation. |

## Required change

- Use the hardware-virtualization-capable `container-compose-release` Apple-silicon runner for Current packages.
- Start a clean, isolated matched runtime, then execute the entire lifecycle outside VHS before rendering anything.
- Set `CONTAINER_COMPOSE_CONTAINER` for every recorded Compose process so the plugin checks that isolated runtime rather than a host installation.
- Remove only the demo project before recording so the first `up` visibly starts services; retain project volumes with the intermediate `down --remove-orphans`.
- Record and fail on: first `up`, `stats`, `ps`, nginx health, Alertmanager readiness, a write to a marker in `nginx_cache`, retained-volume shutdown and a JSON listing that identifies the Compose-owned volume, second `up`, second `stats`/`ps`/health, a read of the same marker, and final `down --volumes --remove-orphans` plus empty `ps --all`.
- Render only the fresh, failure-gated transcript. VHS markers must be output-only reads, so it can never type a lifecycle command while one is running. Show the verified first `up` command/output with compact per-service start summaries, then replay the complete second `up` and final `down` command/output at a readable pace so retained-volume reuse is unambiguous.
- Publish a partial transcript artifact on workflow failure and include the failed command output in the verifier error, so a release-runner failure is diagnosable without guessing from a red job summary.

## Commit tracking

- `fix(release): harden current demo recording`
- `fix(release): prove monitoring demo volume reuse`
- `fix(release): make volume reuse visible in demo` (`ac95e92b71270b37b2a3298bba86f50f16780a70`)

## Code map

- `Tools/release/record_monitoring_stack_transcript.py` is the narrow runtime boundary: it performs the fifteen-step verification cycle, writes and rereads a named-volume marker, records the retained volume as JSON before the reuse start, clears only stale transcript logs, and includes captured output when a command fails.
- `.github/workflows/prebuilt-binaries.yml` packages the matched runtime and plugin, executes that verifier, requires all fifteen logs, uploads a partial transcript on failure, validates the tape, and publishes the generated GIF.
- `docs/container-compose-demo.tape` presents the real transcript at a readable pace while clearing its one-time replay setup before the viewer sees the lifecycle, including both shutdowns and the second startup's marker read.
- `examples/monitoring-stack/docker-compose.yaml` includes a portable `nginx_cache` named volume that visibly remains after the non-destructive down.
