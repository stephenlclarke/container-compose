# Feature request: expose OCI process OOM score adjustment

## Summary

Expose the existing OCI `process.oomScoreAdj` field through the public
`LinuxProcessConfiguration` API.

## Generic behavior

- Accept an optional integer OOM score adjustment on a Linux process.
- Preserve `nil` as the runtime default rather than synthesizing a score.
- Project the configured value into the generated OCI process specification for
  initial and exec processes.

## Rationale

The OCI process model already supports this field, but the public
Containerization configuration previously did not project it. Exposing the
existing generic primitive avoids any Docker or Compose types in the runtime.

## Upstream overlap review

No open `apple/containerization` issue or pull request matching `oomScoreAdj`
or OOM score adjustment was found during the 2026-07-17 slice review.

## Apple-shaped split

This is a Containerization-only projection from the public process model to the
existing OCI model. Value-range policy and Compose-file parsing remain in the
calling layers. This is a handoff document only: no Apple remote was pushed.
