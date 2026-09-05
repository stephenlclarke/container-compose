# Issue 488: make the recoverable pipeline reliable and efficient

## Problem

The matched-stack pipeline exposed three workflow defects on 5 September 2026. Its long isolated stage root made nested runtime fixture socket paths exceed Darwin's 103-byte Unix-domain socket limit, producing 54 failures and one error after 247.845 seconds. When that failure terminated sibling work, a fake `colima start` descendant escaped the task boundary and could trigger a Keychain dialog after the build had stopped. Compose source validation also serialized executable tool and parity-harness suites before either functional lane could begin.

These are build-workflow failures rather than product regressions. Retrying the same graph would waste another cycle and could leave an unattended process waiting for user interaction.

## Required work

- Use a short, marker-protected execution root that preserves enough socket path budget for nested fixtures.
- Forward task cancellation to the existing process-session deadline supervisor and wait for its bounded cleanup.
- Keep source validation fail-fast and run each executable tool suite once with bounded parallelism alongside Swift validation.
- Retain the failure counts, timings, and final validation evidence in the build-workflow review.

## Acceptance boundary

The issue is complete when the focused socket-path and cancellation regressions pass, Nextflow lint and plan accept the graph, and the recoverable repository profile completes from a clean immutable commit without orphaned descendants. Release-only CodeQL, DocC, parity, and packaging are outside this workflow slice.

Tracked by [issue #488](https://github.com/stephenlclarke/container-compose/issues/488).
