# Feature request: configure process OOM score adjustment

## Summary

Add a generic process-level `--oom-score-adj SCORE` setting to `container`.

## Generic behavior

- Preserve an optional integer score in `ProcessConfiguration`.
- Apply it to initial, healthcheck, exec, and machine process projections.
- Accept a negative score in the conventional separated CLI form, for example
  `container run --oom-score-adj -250 alpine sleep 1`.
- Leave absent values unset so existing persisted configurations retain the
  runtime default.

## Upstream overlap review

No open `apple/container` issue or pull request matching OOM score adjustment
was found during the 2026-07-17 slice review.

## Apple-shaped split

The process model and CLI switch are generic Container functionality. OCI
projection belongs in Containerization; Compose-file parsing belongs in the
Compose plugin. This is a handoff document only: no Apple remote was pushed.
