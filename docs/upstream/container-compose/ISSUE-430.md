# Issue 430: align 0.14 exit-control runtime smoke checks

## Problem

The stable 0.14.1 release gate reached the matched Compose runtime stage and
exposed three stale dry-run assertions. Exit-controlled `compose up`
intentionally stops and retains containers for later inspection and log access,
and focused core tests already enforce that contract. The mainline runtime
smoke checks still expected `container delete`, so correct runtime behavior
failed the release gate.

The same assertion correction was applied to the 0.13 maintenance line by pull
request [`#408`](https://github.com/stephenlclarke/container-compose/pull/408),
but was not propagated to main.

## Required work

- Assert `container stop` for `--abort-on-container-exit` and
  `--exit-code-from` dry-run plans.
- Assert that those plans do not emit `container delete`.
- Re-run only the matched runtime smoke test first, then resume the stable
  release from its valid checkpoint.

## Acceptance boundary

The issue is complete when the three corrected assertions pass against the
matched 0.14.1 stack and the exact-head release gate advances beyond the
checkpointed Compose runtime stage.
