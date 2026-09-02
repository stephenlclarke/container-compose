# Issue 436: pin the final reviewed 0.14.1 support stack

## Problem

Stable 0.14.1 preflight correctly stopped before artifact production when Apple
Containerization advanced. The support forks now contain the reviewed upstream
sync, reusable-vsock lifecycle repairs, and the grpc-go security update, but
Compose still points at the preceding immutable stack.

## Resolution

Consume Containerization pull request
[#68](https://github.com/stephenlclarke/containerization/pull/68) through
Container pull request
[#196](https://github.com/stephenlclarke/container/pull/196), then pin both
signed merge commits in Compose before stable validation resumes.

## Acceptance criteria

- `Package.swift`, `Package.resolved`, and the release stack manifest agree.
- Status, architecture references, README fork metrics, commit classifications,
  and handoff evidence describe the same immutable support-fork heads.
- Focused stack-consistency and documentation checks pass.
- Exact-head hosted review and CI pass before the branch merges.
- The published `current` package proves the merged Compose and support-fork
  revisions before the stable 0.14.1 controller is restarted.
