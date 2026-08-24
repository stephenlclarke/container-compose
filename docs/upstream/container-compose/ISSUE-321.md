# Issue 321: remove documentation and demo work from the release critical path

## Problem description

The documentation workflow builds four unrelated Swift packages serially on one hosted macOS runner. A cold run therefore pays the sum of all four DocC builds before Pages can deploy.

The Current package workflow also records the live VHS demo before it can attest packages, publish the Current release, or update Homebrew. That recording starts a nested-virtualization runtime from a run-specific path and can encounter macOS Local Network privacy approval. A visual documentation artifact must not hold the signed release transaction open or leave an unattended runner waiting for a dialog.

The full sibling gate has the same unattended-risk class for a different reason: Container coverage installs newly instrumented source binaries immediately before its VM-backed integration tests. Without the release identity those binaries are ad-hoc signed, so every rebuild presents macOS privacy control with a different code identity.

The GitHub CodeQL workflow is already an isolated, GitHub-authoritative Linux/AMD64 Go scan. Moving it to the release Mac would add contention without shortening its current execution.

## Requested outcome

- Build the Compose, Container, Containerization, and Kubernetes DocC products concurrently on hosted macOS runners, then assemble one Pages artifact after every site succeeds.
- Keep CodeQL on hosted Ubuntu and keep its release authority independent of the Mac release queue.
- Publish signed packages, attestations, the Current release, and the atomic Homebrew pair without waiting for VHS.
- Record the Current demo in a separate recoverable workflow on the nested-virtualization-capable self-hosted Mac.
- Reuse one marker-protected internal-volume runtime path so the signed runtime does not appear as a new executable location on every run.
- Sign the freshly installed Container coverage runtime with the same Developer ID identity as the immutable packaged candidate before any VM-backed integration starts.
- Reuse an explicitly selected packaged Container candidate in Compose runtime and parity gates instead of rebuilding the already-validated sibling source again.
- Bound the complete recording process group, retain failure diagnostics, and never automate or wait indefinitely for a macOS privacy dialog.
- Recheck main, the `current` tag, and the Current release target immediately before replacing the mutable demo asset.
- Reduce recording work without changing its observable scenario.

## Acceptance evidence

- The documentation matrix contains four independent hosted macOS jobs and the Pages upload job depends on the complete matrix.
- Generic `Makefile` changes no longer trigger a documentation rebuild.
- The package workflow contains no VHS installation, runtime demo, demo init-image validation, or demo asset requirement.
- The Current Demo workflow downloads checksum-verified, Developer-ID-verified exact-SHA package assets and validates the matched init image.
- The demo runtime uses `/private/tmp/container-compose-current-demo`, validates its marker, owner, and mode, and wraps both runtime cleanup and VHS in the existing process-group deadline supervisor.
- Full stack validation rejects a missing or malformed signing fingerprint, passes that identity only to Container source-runtime targets, and fingerprints it with the Container checkpoints.
- Compose runtime and parity targets build sibling Container source only for the default `container` selector; release-candidate paths are reused.
- A stale recording exits without replacing the current demo.
- Current asset retention preserves the last good demo until the separate workflow replaces it.
- The tape uses 24 frames per second.
- Focused workflow regressions, YAML/action validation, Markdownlint, and `git diff --check` pass.

## Scope

This changes build orchestration and one mutable documentation asset. It does not change Compose runtime semantics, weaken package/signing/attestation/Homebrew authorities, enable the owner-disabled CodeQL workflow, grant privacy permissions, or move nested-virtualization work to an incapable hosted runner.

Refs [#321](https://github.com/stephenlclarke/container-compose/issues/321).
