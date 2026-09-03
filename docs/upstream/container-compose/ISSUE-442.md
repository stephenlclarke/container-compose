# Issue 442: preserve runner control during Swift coverage builds

## Problem

The self-hosted macOS Current validation lost its GitHub job lease three times while Swift compiled the coverage graph. Runner diagnostics show successful initial lease acquisition followed by a missing renewal window, `TaskAgentJobNotFoundException`, and server-directed worker cancellation before tests produced a result.

The first mitigation bounded SwiftPM concurrency at eight jobs. Pull-request validation then crossed compilation while renewing its lease, but exact-main run [33715390806](https://github.com/stephenlclarke/container-compose/actions/runs/33715390806) lost the same lease after 11 minutes. The runner log also records broker connection resets while the machine is idle. Compiler scheduling therefore cannot make this control channel authoritative.

The source checks and both tool-test lanes passed in every affected run. Replaying the same self-hosted job would waste those checkpoints and retain the known runner-protocol failure.

## Required work

- Run the unit/coverage/CLI-smoke lane on GitHub's managed macOS 26 ARM64 image.
- Pin Xcode 26.6 explicitly so the toolchain cannot drift with the image default.
- Keep VM-backed integration on the local, content-addressed release graph where it can resume independently of a GitHub runner lease.
- Preserve the existing job and step timeouts.
- Verify that exact-main Current validation reaches a real test result.

## Acceptance boundary

The issue is complete when workflow and tool tests pass, exact-head review is clear, and managed exact-main Current validation completes with Xcode 26.6 and publishes the matched Current stack.

Related issue: [#442](https://github.com/stephenlclarke/container-compose/issues/442).
