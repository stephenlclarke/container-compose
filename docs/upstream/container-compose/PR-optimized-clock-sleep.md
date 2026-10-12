# fix(runtime): avoid generic clock sleep specializations

## Resulting behavior

Core test helpers and the API-socket credential deadline use the existing cancellation-aware `ComposeTaskSleep` wrapper instead of generic `Task.sleep(for:)`. Stock Engine environment capture and foreground cancellation polling use the same wrapper. Sleep durations, error propagation, cleanup and test assertions remain unchanged. No dependency pin or binary-layer archive changes.

The Bazel test configuration enables internal imports in optimized project modules. The feature applies to test commands; product build configuration and all eight profile/group dependency recipe identities are unchanged. No command-line admission restriction is relaxed.

## Validation

Before the correction, optimized Core invocation `2eb445f9-5dd5-42d1-9b76-786c4a28e726` aborts in the identified pending-operation helper. The original failure and crash report are retained. Complete corrected enhanced Core and temporary-file suites and the affected stock Engine suite remain required on immutable source. Swift's reported workaround and the existing project wrapper motivate the change; a passing focused test alone is not full stack qualification.

## Compatibility and remaining scope

This reuses the wrapper's established nanosecond resolution and saturation behavior. It does not alter the published diagnostic candidate or its historical measurements. The production source change requires a new upper-layer candidate before further performance qualification. Reuse all published lower archives and baseline measurements. Full logging, newest-stack and release gates remain pending.

See [the companion issue](ISSUE-optimized-clock-sleep.md).
