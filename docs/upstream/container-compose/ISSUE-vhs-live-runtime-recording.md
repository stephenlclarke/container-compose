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
- Record and fail on: first `up`, `stats`, `ps`, nginx health, Alertmanager readiness, retained-volume listing, second `up`, second `stats`/`ps`/health, and final `down --volumes --remove-orphans` plus empty `ps --all`.
- Render only the fresh, failure-gated transcript. VHS markers must be output-only reads, so it can never type a lifecycle command while one is running.

## Commit tracking

- `fix(release): harden current demo recording`

## Code map

- `Tools/release/record_monitoring_stack_transcript.py` is the narrow runtime boundary: it performs the thirteen-step verification cycle and writes marked logs only after each command succeeds.
- `.github/workflows/prebuilt-binaries.yml` packages the matched runtime and plugin, executes that verifier, requires all thirteen logs, validates the tape, and publishes the generated GIF.
- `docs/container-compose-demo.tape` presents the real transcript at a readable pace while clearing its one-time replay setup before the viewer sees the lifecycle.
- `examples/monitoring-stack/docker-compose.yaml` includes a portable `nginx_cache` named volume that visibly remains after the non-destructive down.
