# Reset retained Current VHS runtime state

## Problem

The Current packaging job runs on a self-hosted macOS runner and stages its
matched runtime under `${RUNNER_TEMP}/current-build-demo`. That directory can
survive a prior job. The VHS step previously unpacked a new package over the
retained directory without first stopping the old CLI or clearing its app
root.

During Current run `30068134568` attempt 1, another source runtime was already
registered with launchd. The tape visibly typed its matched
`container system start --app-root ...`, that command rejected the different
app root, and the recorder correctly waited rather than fabricating a running
status. The publication attempt was cancelled because the required
`status running` output could never appear.

## Expected behavior

- Stop a retained demo CLI before replacing its package and app root.
- Fall back to the runner's installed `container` CLI when no retained demo
  binary exists.
- Remove the complete retained demo root before extracting exact artifacts.
- Keep startup inside the visible typed VHS session.
- Keep all command results live; do not add transcript replay or marker input.
- Preserve the fail-closed post-recording cleanup.

## Acceptance criteria

- [x] The old runtime stop runs before demo-root deletion.
- [x] Demo-root deletion runs before archive extraction.
- [x] A focused workflow-policy test proves the ordering.
- [x] The tape still contains typed commands and live screen waits only.
- [x] `Replay` and `Marker` remain absent.
- [ ] Exact-main Current packaging publishes the rendered GIF and matched
  runtime after this fix.

## Implementation

Signed implementation:

- `930984761daf09d3341e1b3dc5982f23c5a57349`
  `fix(release): reset current demo runtime root`

This is Compose release-runner ownership. No Apple Container,
Containerization, or builder-shim change is needed.
