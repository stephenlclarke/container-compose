# Issue 416: preserve Git history for history-sensitive release stages

## Problem

The recoverable release pipeline reconstructs ordinary validation stages from deterministic Git-tree archives. Full-repository checks that use Hawkeye's Git-aware copyright-year validation then see only the pipeline's synthetic 2000 commit, so valid Containerization, Container, and builder licence headers are rejected.

Tracking issue: [`#416`](https://github.com/stephenlclarke/container-compose/issues/416).

## Required outcome

- Preserve exact Git history when a full-repository stage explicitly requests commit metadata.
- Make each history-sensitive hosted release validation stage opt into that source contract.
- Keep partial-source stages on deterministic Git-tree archives.
- Retain verified Git-bundle reconstruction and exact-commit checkout.
- Cover the source-format selection policy with a focused regression.

## Acceptance evidence

- Builder, Containerization, and Container release validation declare a full-repository commit identity.
- Full-repository commit capture selects `git-bundle` reconstruction.
- Partial-source capture remains `git-tree-archive` reconstruction.
- Focused tests, Python compilation, `git diff --check`, a signed Conventional Commit, and exact-head review pass.

## Scope

This corrects release-stage reconstruction only. It does not change product behavior, generated artifacts, or the checks run by each repository.
