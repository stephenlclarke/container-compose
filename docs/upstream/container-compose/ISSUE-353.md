# Issue 353: recover retained package artifacts for published benchmarks

## Problem

The first published-artifact benchmark for 0.14.0 versus 0.13.0 failed before timing began because the older stable GitHub release has no attached assets. The successful 0.13.0 package workflow still retains the exact signed runtime and Compose archives, their checksum sidecars, and immutable run metadata. Rebuilding those products would violate the benchmark's released-artifact contract and would make the comparison irreproducible.

Tracking issue: [`#353`](https://github.com/stephenlclarke/container-compose/issues/353).

## Required outcome

- Prefer the complete asset set attached to the stable GitHub release.
- When that set is absent or incomplete, select only an exact-version, successful, completed `workflow_dispatch` package run from this repository.
- Require exactly one unexpired runtime artifact and one unexpired Compose artifact from the selected run.
- Preserve the Developer ID, sidecar checksum, historical Homebrew formula, release-tag commit, and matched-stack verification performed for release assets.
- Record the exact release or Actions run used as the artifact source in the durable benchmark manifest and report.
- Never build a source product while recovering benchmark inputs.
- Skip DocC for repository Markdown that is not consumed by the DocC generator while retaining forced manual and release documentation builds.

## Acceptance evidence

- Focused tests reject failed, incomplete, wrongly triggered, missing, duplicate, or expired package authorities.
- The retained 0.13.0 package run and both required artifact IDs resolve through the same checked implementation used by the workflow.
- Actionlint, Python compilation, focused benchmark and DocC-classifier tests, and `git diff --check` pass.
- The implementation lands through a signed Conventional Commit and protected pull request before the benchmark is retried.
