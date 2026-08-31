# Issue 355: fail fast on incomplete published guest-image authority

## Problem

The published 0.14.0 versus 0.13.0 benchmark recovered the signed host runtime and Compose archives, but neither stable release retained the exact guest `vminit` OCI archive used by its release gate. The runtime wrapper consequently inherited the operator's `XDG_CONFIG_HOME` and selected Apple's `vminit:0.40.0` for the 0.13.0 fork runtime. That guest does not implement the fork's container-process RPC, so the first candidate startup failed after Docker timing had already begun.

Tracking issue: [`#355`](https://github.com/stephenlclarke/container-compose/issues/355).

## Required outcome

- Isolate runtime configuration for every managed runtime invocation, even when no matched guest source was supplied.
- Require a checksummed `container-vminit-arm64.oci.tar` release asset for both compared versions before runtime startup or timing.
- Publish and verify that exact guest archive as part of every future stable release closure.
- Validate that the OCI archive contains the local Compose alias and the exact Containerization revision recorded by the release tag.
- Record the guest archive digest and immutable references in the benchmark manifest and runtime fingerprints.
- Run one candidate-only lifecycle preflight before any timing samples are recorded.
- Retain manifests, checksums, fingerprints, and partial evidence after a preflight failure.
- Never rebuild a missing historical guest image or substitute a debug, cached, registry, or machine-local image.

## Acceptance evidence

- Focused runtime-wrapper regression proves an inherited user `vminit` configuration cannot enter an isolated run and no unnecessary restart is added.
- Focused benchmark tests prove the guest asset is mandatory, exact OCI references are validated, candidate preflight precedes timing, and failure evidence is retained.
- The workflow fails before runtime startup when a published release lacks the exact guest closure.
- Bash syntax, ShellCheck, Actionlint, Python compilation, focused tests, Markdown lint, and `git diff --check` pass.
- The implementation lands through a signed Conventional Commit and protected pull request before any further published benchmark attempt.
