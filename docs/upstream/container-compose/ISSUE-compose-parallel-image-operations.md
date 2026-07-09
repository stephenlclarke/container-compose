# Support root `--parallel` for image operations

## Summary

`container compose --parallel N pull` and `container compose --parallel N push` should honor Docker Compose's global parallelism flag for repeated image work instead of accepting the option as parser-only compatibility.

Docker Compose treats `--parallel` as a root option. `container-compose` already parsed it, but help marked it unsupported and orchestration ignored the value. That made large image pull/push batches slower than necessary and left users with a misleading accepted-but-unused flag.

## Acceptance Criteria

- `container compose --parallel 2 pull` runs at most two image pull operations concurrently.
- `container compose --parallel -1 push` runs selected image push operations without a local cap.
- `container compose --parallel 0 pull` rejects the value before side effects.
- Dry-run output remains deterministic and ordered.
- Build, create, start, and dependency-sensitive reconciliation remain ordered until their dependency and progress semantics are explicitly reviewed.
- Root help marks `--parallel` as partially supported and describes the image-operation scope.
- Focused tests cover bounded pull concurrency, unlimited push concurrency, invalid values, and help status.

## Notes

This is a Compose-side scheduling improvement. It does not require new Apple runtime APIs because it uses the existing image manager pull/push operations. Broader lifecycle parallelism remains intentionally out of scope until the service dependency graph, progress output, and runtime reconciliation ordering can be changed without surprising users.
