# Close the macOS Phase 4 metadata, state, and events boundary

## Problem

The Phase 4 implementation was delivered as independent Apple-shaped slices,
but it did not have one fail-closed validation entry point or one handoff that
defined the completed macOS boundary. That made it too easy to validate only a
subset or to mistake unavailable Docker Engine actions for unfinished Compose
adapter work.

## Scope

Phase 4 is complete on macOS when the matched stack preserves and validates:

- OCI annotations independently from labels;
- exposed-port metadata independently from published host ports;
- explicit empty command and entrypoint overrides;
- distinct Docker `created` and `exited` service-state projection;
- the selected terminal status for `up --exit-code-from`;
- terminal `kill`, `die`, and `destroy` lifecycle events; and
- `exec_create`, `exec_start`, and `exec_die` lifecycle events.

`make docker-compose-phase4-parity` must run every corresponding strict Docker
Compose V2 fixture. The aggregate target must remain additive to the full stack
release gate rather than replacing unit, coverage, hosted, Sonar, or live
runtime validation.

## Apple-shaped boundary

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Carry generic OCI annotations. No Docker state or event vocabulary is introduced. |
| `apple/container` | Persist generic annotations and exposed ports, clear an inherited image entrypoint, and emit generic lifecycle observations at existing process and cleanup boundaries. |
| `container-compose` | Translate Compose metadata, derive Docker CLI state names, preserve selected exit status, and render Docker-shaped event actions. |

The lower forks remain usable by clients that do not import Compose types.
Compose-specific translation stays in `container-compose`.

## Required parity evidence

The aggregate gate owns these existing checks:

```console
make docker-compose-phase4-parity
```

That command runs:

- `check-compose-oci-annotations.sh`;
- `check-compose-exposed-ports.sh`;
- `check-compose-empty-process-overrides.sh`;
- `check-compose-state-status.sh`;
- `check-compose-events.sh`; and
- `check-compose-up-exit-code-from.sh`.

Every checker compares against the pinned Docker Compose V2 reference. Checks
with a generic Apple runtime path also run in the isolated live release lane.

## Non-goals

- Windows container behavior.
- Docker Engine or Docker socket emulation.
- Linux-host-only OOM telemetry.
- Inventing `dead`, `restarting`, or `removing` without runtime state.
- Inventing OOM, explicit restart, rename, resize, update, interactive attach,
  or detach events without an observable generic runtime action.

Those gaps remain explicit in `STATUS.md` and become implementable only after
an Apple-shaped primitive exists.

## Acceptance criteria

- [x] Every macOS-feasible Phase 4 slice has unit and strict Compose parity
  coverage.
- [x] One aggregate target fails when any Phase 4 checker fails.
- [x] Lower-fork changes remain generic and Compose-free.
- [x] Remaining primitive gaps are documented without false support claims.
