# Compose named-volume reuse and Current demo recording

## Problem

Docker Compose v2 treats a project-scoped named volume as reusable state: a
second `compose up` must not fail merely because the volume already exists.
The Container runtime can return that condition in two compatible forms:

- `ContainerizationError(.exists)` from the current resource API;
- a legacy XPC-wrapped `ContainerizationError` whose volume-specific message
  reports that the volume already exists.

The Compose adapter previously ignored only the direct `VolumeError` form.
Consequently a repeated `up --detach --wait` could stop after the first
successful create with `volume '<project>_cache' already exists`.

The Current-release VHS job also invoked the tape without first starting the
matched packaged Container service. That allowed recordings to show an API
server-not-running diagnostic, and it could publish a prior demo asset when a
new recording was not generated.

## Scope and boundary

This is a Compose-layer reconciliation and release-recording fix. It does not
require a new Apple Container or Containerization primitive. The adapter
recognizes the existing semantic condition and leaves the generic runtime API
unchanged.

| Layer | Responsibility |
| --- | --- |
| `apple/containerization` | Existing `ContainerizationError(.exists)` transport. |
| `apple/container` | Existing volume service and XPC boundary. |
| `container-compose` | Docker Compose idempotent volume reconciliation, Docker Compose v2 parity coverage, and Current demo automation. |

An upstream Container improvement may preserve the typed volume-exists code
across every XPC version, but Compose must continue accepting the documented
legacy transport while supported packaged runtimes coexist.

## Required change

- Treat `ContainerizationError(.exists)` as successful named-volume reuse.
- Treat an XPC-wrapped error as reuse only when its message is explicitly about
  an existing volume; propagate all other runtime errors.
- Cover both transports with unit tests and use a real Compose YAML fixture to
  start the project twice, read a persisted marker, and tear it down.
- Add a no-daemon Docker Compose v2 parity check that compares the normalized
  fixture and validates Compose's volume-create/mount dry-run plan.
- Start the isolated, packaged Container service before rendering the Current
  tape; always remove the destination first, render the tape, require a
  non-empty new GIF, and stop the isolated service on exit.

## Commit tracking

- Compose implementation and generated demo:
  `bba6f81916a957b02b276a9515f246a032420d53`
  (`fix(compose): reuse named volumes in runtime demos`).
