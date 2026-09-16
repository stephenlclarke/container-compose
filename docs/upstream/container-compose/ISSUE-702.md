# Issue 702: automate local residue cleanup and GitHub hygiene

## Problem

The recoverable Container-family build graph had a safe manual transient cleanup tool, but normal builds did not invoke it. Successful, failed, cancelled, or interrupted work could therefore leave marker-owned compiler scratch and process-temporary state until an operator remembered the separate command. The local worktree audit was intentionally read-only, while GitHub had no scheduled fail-closed branch reconciliation. Repository hygiene depended on memory rather than the build contract.

## Required work

- Run allowlisted, marker-validated transient cleanup before and after every native stack build while holding the build lock.
- Preserve exact pins, promoted artifacts, timings, and all retained release evidence.
- Retain human-readable and machine-readable cleanup receipts.
- Add deterministic safety and failure-path regressions.
- Add a scheduled/manual GitHub workflow that deletes only unchanged, unprotected exact heads of aged merged pull requests after a fresh race check and an atomic expected-SHA lease, then restores the exact head without overwriting newer work if a pull request became active during deletion.
- Preserve and report default, protected, upstream-handoff, release, archive, active, changed, and ambiguous branches.

## Acceptance boundary

Cleanup must never claim an unmarked root, follow a symbolic link, cross into retained storage, create a cleanup target before acquiring the build lock, or run beside an active build. GitHub deletion must revalidate the exact SHA, absence of an open pull request, and exact merged-pull-request proof immediately before changing the ref, then atomically require that same SHA at the server and restore the exact head if a new or reopened pull request became active during deletion. Tags, releases, issues, workflow runs, Actions caches, artifacts, and unrelated local worktrees are outside the deletion boundary.

Tracked by [issue #702](https://github.com/stephenlclarke/container-compose/issues/702).
