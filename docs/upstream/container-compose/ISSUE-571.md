# Issue 571: resolve retained sibling release authority from remote main

## Problem

The retained 0.14.3 transaction correctly refreshed its Compose candidate to the reviewed Current parent, but its sibling Containerization and Container clones still had the `main` commits captured when the transaction began. The stable preflight then compared the Current manifest with those stale local branches and stopped before expensive validation even though the published Current stack already matched GitHub.

Container also excludes the mutable `homebrew-main` tag while fetching release refs. Supplying only that negative refspec prevented Git from applying the remote's normal positive branch refspec, so the retained Container clone could not refresh `fork/main`.

## Scope

- Fetch each sibling's canonical writable remote at the stable Current boundary.
- Cleanly fast-forward retained sibling `main` branches to the fetched remote commits.
- Fail closed for dirty, divergent, or unresolvable sibling checkouts.
- Preserve dry-run as a read-only remote-authority check.
- Keep completed parity evidence and all other valid release checkpoints intact.

## Acceptance evidence

- A focused behavioral regression advances three local Git remotes, proves dry-run leaves the stale retained clones untouched, then proves execution fast-forwards all three clones to the exact remote commits.
- The regression exercises Container's positive branch and negative mutable-tag refspecs together.
- Focused retained-workspace recovery tests pass.
- Bash syntax, ShellCheck, Python formatting, and diff checks pass.
- Required pull-request checks pass on the exact head.

Implementation: [pull request 572](https://github.com/stephenlclarke/container-compose/pull/572).
