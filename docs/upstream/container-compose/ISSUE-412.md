# Issue 412: keep recoverable release state on internal storage

## Problem

Stable Release Gate run [`33575857011`](https://github.com/stephenlclarke/container-compose/actions/runs/33575857011) blocked before pipeline startup while its service-launched self-hosted runner executed `mkdir -p /Volumes/SSD/github/.container-compose-release-pipeline`. A live sample remained inside the kernel `mkdir(2)` call for more than ten minutes. Cancellation marked the workflow complete but could not reap that blocked child until it was terminated explicitly.

The gate already stages VM and XPC source inputs on internal storage to avoid macOS removable-volume privacy waits. Its recoverable Nextflow state root crossed the same boundary earlier in the workflow and therefore remained capable of blocking unattended releases.

Tracking issue: [`#412`](https://github.com/stephenlclarke/container-compose/issues/412).

## Required outcome

- Store recoverable pipeline state at a stable absolute path on the self-hosted runner's internal workspace.
- Keep the state outside child checkout paths so `actions/checkout` cleanup does not erase resumable sessions.
- Preserve the same path across workflow attempts so `pipeline-resume` remains deterministic.
- Reject reintroduction of a `/Volumes` state root in focused workflow policy coverage.
- Resume the guarded 0.13.1 publication from its existing signed tag and immutable init-image authority.

## Acceptance evidence

- The focused stable-gate workflow policy test requires the internal workspace path and excludes `/Volumes`.
- Actionlint accepts the workflow expression at job scope.
- The replacement Stable Release Gate passes pipeline bootstrap without a removable-volume prompt or blocked filesystem call.
- The signed 0.13.1 candidate, release authority, assets, and Homebrew pair remain unchanged.

## Scope

This changes only the self-hosted stable-gate state location. It does not weaken state-root markers, cleanup guards, candidate provenance, checkpoint identity, runtime validation, package publication, or Homebrew verification.
