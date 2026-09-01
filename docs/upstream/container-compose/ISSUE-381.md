# Issue 381: run CodeQL only for stable releases

## Problem

The Current package graph started the release-only CodeQL job after ordinary main CI. That duplicated hosted analysis on non-release commits and contradicted the documented rule that CodeQL is release evidence.

Tracking issue: [`#381`](https://github.com/stephenlclarke/container-compose/issues/381).

## Required outcome

- Run package-graph CodeQL only for an explicit stable `MAJOR.MINOR.PATCH` tag.
- Let Current packaging proceed after successful fail-fast preflight without accepting a failed CodeQL job.
- Build the mutable Current quality snapshot from exact-commit SonarQube evidence without polling for CodeQL.
- Keep stable packaging blocked unless the exact-tag CodeQL job succeeds.
- Preserve workflow cancellation before package publication.
- Preserve the manual published-release recovery workflow.

## Acceptance evidence

- Focused workflow and quality-snapshot tests cover stable-only CodeQL, the conditional package dependency, and cancellation.
- Actionlint and `git diff --check` pass.
- Exact-head review finds no further issue.
