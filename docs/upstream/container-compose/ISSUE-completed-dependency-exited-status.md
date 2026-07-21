# Compose completion dependencies must accept the runtime `exited` state

## Problem

Compose `depends_on` with `condition: service_completed_successfully` accepts
a one-shot dependency only after its container completes with status `0`.
The macOS runtime preserves that completion and exit code, but its discovery
view can report the completed container as `exited` rather than `stopped`.

`container-compose` previously accepted only `stopped`. Consequently a valid
one-shot dependency was rejected before its dependent service started:

```text
unsupported compose feature: service 'subpath' dependency
'subpath-preparer' container '<name>' is exited
```

The Docker Compose V2 image-volume fixture reproduces this with a preparer
that creates the `volume.subpath` directory and exits successfully before the
dependent service mounts it.

## Resolution

Treat `exited` and `stopped` as completed runtime states when an exit code is
present. Both retain the same generic lifecycle fact Compose requires: the
container has completed and its code is available for the existing success
check. Running and stopping containers continue to use the runtime wait
primitive; all other states still receive the existing unsupported-state
diagnostic.

## Apple-shaped boundary

| Layer | Responsibility |
| --- | --- |
| `apple/container` | Report generic container lifecycle state and stored exit code. |
| `container-compose` | Map equivalent completed states to the Compose completion condition. |

No Apple runtime API, Linux-specific behavior, or Docker-shaped lower-layer
abstraction is added. The correction remains in the Compose adapter where
Compose dependency semantics are already owned.

## Source map

- [`74d02bbdcc6d950cacd31868ae09503fc9d9aff9`](https://github.com/stephenlclarke/container-compose/commit/74d02bbdcc6d950cacd31868ae09503fc9d9aff9),
  `fix(deps): accept completed service exit status`:
  - `Sources/ComposeCore/ComposeOrchestratorWaitAndPorts.swift`
  - `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift`
- Docker Compose V2 parity fixture:
  `Tools/parity/fixtures/image-volumes/compose.yaml`.
- Live parity assertion:
  `Tools/parity/check-compose-image-volumes.sh`.

## Acceptance criteria

- A successful `exited` dependency starts its dependent service.
- A successful `stopped` dependency remains supported.
- A completed dependency with a nonzero exit code still blocks its dependent.
- Source-matched Docker Compose V2 image-volume parity completes the
  preparer/subpath lifecycle and teardown.
