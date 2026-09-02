# Issue 414: fingerprint staged Container checkout content

## Problem

Stable release validation relocates the exact Container checkout beneath a fresh system-volume runtime root. The release-environment fingerprint already normalizes the relocated Containerization checkout by its Git tree and deliberately copied release inputs, but `CONTAINER_STACK_REPO` and `CONTAINER_RUNTIME_INIT_BLOCK_REPO` remain tied to their literal paths.

That asymmetry prevents equivalent relocated Container checkouts from reusing a valid checkpoint. More importantly, a changed ignored `.local/bin/hawkeye` can retain the same static Git-tree identity and allow a stale Container checkpoint to be reused.

Tracking issue: [`#414`](https://github.com/stephenlclarke/container-compose/issues/414).

## Required outcome

- Bind both Container checkout selectors to the selected Git tree and staged supplement content.
- Preserve one identity when an equivalent checkout is relocated.
- Invalidate the identity when the staged Hawkeye executable changes.
- Cover the direct runtime selector and the Make command-line selector in a focused regression.

## Acceptance evidence

- Two independent clones with the same Git tree and executable Hawkeye supplement produce the same release-environment fingerprint.
- Changing only the ignored staged Hawkeye executable changes the fingerprint.
- The existing Containerization relocation regression remains green.
- Python compilation, `git diff --check`, a signed Conventional Commit, and exact-head review pass.

## Scope

This changes checkpoint identity only. It does not change runtime behavior, broaden checkpoint reuse, run benchmarks, or alter release artifacts.
