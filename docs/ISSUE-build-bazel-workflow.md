# Native recoverable Container Compose build workflow

## Feature or enhancement request details

The operator requested a Bazel-owned build/test workflow shared with devcontainer: eliminate duplicate work, retain evidence for recovery, keep disposable files on the external SSD and long-lived assets internally, and ultimately publish qualified stable releases. The legacy build/test/release entry points remain until the complete native graph and acceptance gates replace them.

## Compose compatibility impact

Internal implementation improvement. Package.swift and the existing stock/enhanced lockfiles remain the product contract. No Docker parity scope, runtime API visibility, dependency pin or release gate is relaxed.

## Acceptance

Native Swift and Go compilation, all unit/integration/parity suites, meaningful coverage, explicit storage and resource ownership, unchanged-input cache reuse, recoverable signed packaging/publication and current docs must pass before production cutover. Reference parity uses downloaded releases, never rebuilt substitutes. Quiet paired benchmark evidence and installation-first demos remain required.

See [the implementation guide](guides/BAZEL.md) and [the PR handoff](PR-build-bazel-workflow.md) for current evidence and incomplete gates. Owner: this active build migration; terminal condition: reviewed complete workflow merge and qualified stable publication, followed by branch/worktree cleanup.
