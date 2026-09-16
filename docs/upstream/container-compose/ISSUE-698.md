# Issue 698: recover clean retained sibling branches

## Problem

Unattended stable promotion run [35057962271](https://github.com/stephenlclarke/container-compose/actions/runs/35057962271) recovered the retained 0.15.2 transaction and refreshed the Compose release controller, but stopped before validation because the retained Container checkout was clean and still on its preserved `sync/apple-container-cni` branch rather than `main`.

The release controller owns this isolated transaction and requires the exact canonical fork `main` for stable promotion. A clean non-`main` checkout is recoverable without deleting or rewriting its retained branch.

## Scope

- Recover a clean retained sibling checkout from a non-`main` branch to canonical local `main`.
- Fetch and fast-forward that `main` to the freshly resolved canonical remote authority.
- Preserve the non-`main` branch and every commit reachable from it.
- Retain the existing fail-closed behavior for dirty or divergent sibling checkouts.
- Resume the unattended 0.15.2 release only after exact-head review and green checks.

## Acceptance evidence

- A focused behavioral regression places retained Container on a clean non-`main` branch, proves the controller restores and advances `main`, and proves the retained branch remains unchanged.
- Existing dirty and divergent checkout regressions continue to fail closed.
- Bash syntax, ShellCheck, Python formatting, Markdown lint, and diff checks pass.
- Required pull-request checks pass on the exact reviewed head.
- The unattended stable-release workflow resumes the retained transaction and publishes 0.15.2.

Implementation: [pull request 699](https://github.com/stephenlclarke/container-compose/pull/699).
