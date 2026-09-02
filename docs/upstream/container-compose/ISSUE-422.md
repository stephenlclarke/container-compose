# Issue 422: parallelize deterministic source validation

## Problem

Exact-main CI run [`33586037899`](https://github.com/stephenlclarke/container-compose/actions/runs/33586037899) completed 354 release-tool tests in 450.868 seconds and 231 CI-tool tests in 396.840 seconds, then the monolithic Source Checks job reached its fixed 15-minute deadline. The source was functionally green, but two independent suites were serialized on one runner.

Tracking issue: [`#422`](https://github.com/stephenlclarke/container-compose/issues/422).

## Required outcome

- Keep source preflight, static analysis, coverage-tool tests, and parity-harness tests in Source Checks.
- Run the independent release-tool and CI-tool suites on separate hosted runners.
- Preserve `make check` as the complete local validation entry point.
- Fail the existing aggregate Validate context if any parallel prerequisite fails.

## Acceptance evidence

- Focused workflow-policy tests pass.
- Both tool-suite Make targets pass independently.
- Workflow YAML parsing and `git diff --check` pass.
- Exact-head CI completes without the previous deterministic timeout.

## Scope

This changes validation scheduling only. Test content, product behavior, and release artifacts are unchanged.
