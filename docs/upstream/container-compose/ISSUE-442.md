# Issue 442: preserve runner control during Swift coverage builds

## Problem

The self-hosted macOS Current validation lost its GitHub job lease twice while Swift compiled the coverage graph with unbounded concurrency. Runner diagnostics show successful initial lease acquisition followed by a missing renewal window, `TaskAgentJobNotFoundException`, and server-directed worker cancellation before tests produced a result.

The source checks and both tool-test lanes had already passed. Replaying the whole workflow would waste those checkpoints and leave the same runner starvation risk in stable release validation.

## Required work

- Bound SwiftPM build concurrency in the self-hosted runtime-validation job.
- Preserve the existing job and step timeouts.
- Reuse completed workflow jobs when validation resumes.
- Verify that the runner renews its lease throughout the coverage build and reaches a real test result.

## Acceptance boundary

The issue is complete when the workflow passes `--jobs 8` through the existing `SWIFT_TEST_FLAGS` contract, workflow and tool tests pass, exact-head review is clear, and Current validation completes without losing the runner job lease.

Related issue: [#442](https://github.com/stephenlclarke/container-compose/issues/442).
