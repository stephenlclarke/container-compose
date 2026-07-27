# Current VHS recording should recover from launchd teardown races

## Problem

Exact-main Current packaging run
[`30228427993`](https://github.com/stephenlclarke/container-compose/actions/runs/30228427993)
built both matched archives, then failed before publication while recording the
required typed/live VHS demo.

The self-hosted release runner retained many containers from earlier work.
Its pre-recording `container system stop` spent about 15 minutes draining that
state and removing the global `com.apple.container.*` launchd services. The
tape then immediately typed the exact packaged runtime start. Kernel
installation failed with an interrupted XPC connection while the service
namespace was still settling, and the required live `status running` output
never appeared.

The recorder correctly refused to replay or retry a session after typing had
begun. That fail-closed boundary must remain, but the typed command needs a
bounded, visible runtime-start recovery and the workflow must not begin the
recording while launchd teardown is still observable.

## Expected behavior

- Require the complete `com.apple.container.*` launchd namespace to remain
  absent across consecutive observations after the old runtime stops.
- Fail before recording if launchd cannot be queried or the namespace never
  quiesces.
- Visibly type at most one retry of the same exact packaged-runtime start
  command after a short delay.
- Require live `status running` output after the start or its retry.
- Bound the first live-output wait to the two 60-second start attempts plus
  recovery overhead.
- Keep every command and result live; never add Replay, Marker, or transcript
  input.

## Apple-shaped boundary

This is self-hosted Compose release-runner behavior. It changes no Apple
runtime source, public API, Windows path, or Docker-shaped Compose primitive.

## Acceptance

- Launchd quiescence tests cover delayed stop, service reappearance, a
  permanently active namespace, launchctl failure, and invalid bounds.
- Release-policy tests require stop, stable quiescence, demo-root deletion,
  and exact archive extraction in that order.
- The VHS source contains two visible occurrences of the exact start command,
  one `Type` instruction for that recovery group, and a bounded live status
  wait.
- VHS validation, all release tests, Markdownlint, and `git diff --check`
  pass.
- Exact-main Current packaging publishes the matched archives and a nonempty
  live GIF with zero Replay or Marker instructions.
