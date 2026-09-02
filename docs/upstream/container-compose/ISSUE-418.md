# Issue 418: isolate persistent release state from the job workspace

## Problem

Stable release gate run [`33583434090`](https://github.com/stephenlclarke/container-compose/actions/runs/33583434090) failed during bootstrap because its recoverable state root was inside the disposable GitHub job workspace. A preceding job had left that location non-empty without the pipeline safety marker, so `pipeline-state-init` correctly refused to claim it.

Tracking issue: [`#418`](https://github.com/stephenlclarke/container-compose/issues/418).

## Required outcome

- Store recoverable state on internal runner storage outside the checkout workspace.
- Key the state root by the immutable release-candidate SHA.
- Retain the existing marker, canonical-path, and non-symbolic-path checks.
- Reject any resolved state path that falls inside `GITHUB_WORKSPACE`.
- Cover the workflow contract with a focused regression.

## Acceptance evidence

- The state root resolves from the canonical parent of `RUNNER_TEMP`.
- Candidate retries select the same state root while different candidates remain isolated.
- Workflow YAML parsing, focused policy tests, licence checks, `git diff --check`, a signed Conventional Commit, and exact-head review pass.
- The resumed stable gate enters the recoverable release graph without claiming disposable workspace contents.

## Scope

This changes release-state placement only. Product code, release artifacts, and repository validation commands are unchanged.
