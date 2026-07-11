# feat(runtime): add restart policy timing controls

## Commit Tracking

- Commit: `8b1eff72481fa497328414e0483a08c768826f1a`
- Stacks on commit `b41bb830db708bc839c94e01c8a75c7fecbe3db0` in `stephenlclarke/container`.

## Summary

- Add optional restart timing fields to `ContainerRestartPolicy`.
- Carry typed restart timing durations in `ContainerCreateOptions`.
- Apply configured retry delay and successful-run window in
  `ContainerRestartTracker` / `ContainersService`.
- Keep existing restart behavior unchanged when timing fields are absent.

## Motivation and Context

This is a small follow-up to the fork's restart-policy create/runtime slices.
Those slices cover mode and retry count for
[apple/container#286](https://github.com/apple/container/issues/286) and the
direction from
[apple/container#1258](https://github.com/apple/container/pull/1258).
`container-compose` can now map service-level `restart` and the deploy restart
policy mode/retry subset, but Docker Compose `deploy.restart_policy.delay` and
`deploy.restart_policy.window` still need runtime-owned timing primitives.

The timing model belongs in the runtime restart policy rather than in
`container-compose`, because the restart decision happens after the container's
init process exits and the Compose process may no longer be running.
Following JLogan's guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), Docker/Compose duration parsing remains in `container-compose`; this Apple PR should be framed as typed timing fields and scheduler behavior.

## Implementation Details

- `ContainerRestartPolicy` gains:
  - `retryDelayInNanoseconds`
  - `successfulRunDurationInNanoseconds`
- Existing serialized create options remain backward compatible because both
  fields are optional.
- `ContainerCreateOptions` accepts optional typed timing values.
- The local fork also carried `--restart-delay` and `--restart-window`
  management options for local integration testing; an upstream PR should drop
  or soften that bridge if maintainers prefer typed-only configuration.
- `ContainerRestartTracker.restartDelay` returns the configured fixed delay when
  present; otherwise it preserves the existing exponential backoff.
- `ContainersService` uses the configured successful-run window when scheduling
  retry-state reset; otherwise it preserves the existing 10 second default.

## Compatibility Notes

- Existing callers that only set a restart mode keep the same behavior.
- Containers with the default `no` restart policy remain unaffected.
- Timing options require a non-`no` restart policy.
- Compose-specific `condition`, `delay`, `max_attempts`, and `window` parsing
  stays in `container-compose`.

## Testing

Focused validation:

```sh
swift test --filter 'ContainerRestartTrackerTests|ParserTest|ContainerCreateOptionsTests'
```

## Checklist

- [x] Added or updated tests.
- [x] Kept the change focused on one runtime capability.
- [x] Documented compatibility and remaining scope.
- [x] Followed the repository's license/header conventions.
- [x] Kept Compose-specific behavior out of `apple/container`.
