# Pull request: add Linux container pause and resume

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [ ] Documentation update

## Motivation and Context

This change completes the existing `LinuxContainer` paused-state model by adding public `pause()` and `resume()` lifecycle methods.

`containerization` already has the pieces needed for this behavior:

- `LinuxContainer.State.paused`
- `State.PausedState`
- conversions between started and paused state
- `VirtualMachineInstance.pause()`
- `VirtualMachineInstance.resume()`
- `VZVirtualMachineInstance` implementations for pause/resume

The missing piece is the public `LinuxContainer` boundary. Without it, downstream callers such as `apple/container` cannot expose pause/unpause behavior without bypassing `LinuxContainer` state ownership.

Design choices:

- Keep the API small and lifecycle-focused: `pause()` and `resume()`.
- Validate state at the `LinuxContainer` boundary using the existing `startedState(_:)` and `pausedState(_:)` helpers.
- Commit the state transition only after the underlying VM operation succeeds, preserving the prior state on failure.
- Keep process, IO, and relay cleanup unchanged. Pause/resume is a non-terminating lifecycle transition, unlike `stop()`.

Compatibility notes:

- This is intended to support downstream pause and unpause lifecycle commands in `apple/container`, with Compose command semantics mapped in `container-compose`.
- This does not add a new container runtime or scheduler concept.
- This does not alter existing `stop()`, `kill(_:)`, `wait(timeoutInSeconds:)`, or `exec(_:)` behavior.

## Commit Tracking

- Lower runtime code commit: `e172174` in `stephenlclarke/containerization` (`feat(runtime): add linux container pause controls`).
- Container API/CLI code commit: `61a11f4` in `stephenlclarke/container` (`feat(runtime): add container pause controls`), not part of this lower-runtime PR.
- Compose mapping code commit is tracked in `docs/upstream/container-compose/PR-compose-pause-unpause.md`, not part of this lower-runtime PR.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated handoff docs; no public containerization guide change is needed for this lower-runtime API.

Local validation:

```sh
swift test --filter LinuxContainerTests
make fmt
```

Focused tests cover:

- successful create/start/pause/resume lifecycle using a recording VM and agent
- pause rejected before the container is running
- resume rejected before the container is paused

Remaining risks:

- This unit test uses a fake VM/agent to avoid booting a real VM. End-to-end validation should happen in downstream `apple/container` integration tests once the client/API/CLI surface is added.
