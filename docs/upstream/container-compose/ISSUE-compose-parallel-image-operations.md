# Support root `--parallel` for independent engine operations

## Summary

`container compose --parallel N` and `COMPOSE_PARALLEL_LIMIT` should honor Docker Compose's global parallelism controls for independent engine work instead of accepting the option as parser-only compatibility.

Docker Compose treats `--parallel` as a root option. `container-compose` already parsed it, but help marked it only partially supported and orchestration did not cover builds or the environment equivalent. That left users with a misleadingly narrow compatibility surface.

## Acceptance Criteria

- `container compose --parallel 2 pull` runs at most two image pull operations concurrently.
- `container compose --parallel -1 push` runs selected image push operations without a local cap.
- Independent build services run concurrently by default while `service:` additional contexts and `--with-dependencies` retain dependency-safe ordering.
- `COMPOSE_PARALLEL_LIMIT` supplies the limit when the flag is absent; an explicit `--parallel` value wins.
- `container compose --parallel 0 pull` rejects the value before side effects.
- Dry-run output remains deterministic and ordered.
- Create, start, and dependency-sensitive lifecycle reconciliation remain ordered until their dependency and progress semantics are explicitly reviewed.
- Root help marks `--parallel` as supported and describes its Docker-compatible scope.
- Focused tests cover bounded pull/build concurrency, unlimited defaults, environment precedence, build dependency layers, invalid values, and help status.

## Notes

This is a Compose-side scheduling improvement. It does not require new Apple runtime APIs: pull/push use the existing image manager operations, and builds invoke independent existing `container build` operations. Build layers retain `service:` additional-context and requested runtime build dependencies before their consumers run. Broader lifecycle parallelism remains intentionally out of scope until the service dependency graph, progress output, and runtime reconciliation ordering can be changed without surprising users.
