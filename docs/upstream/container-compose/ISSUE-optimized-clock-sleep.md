# Optimized Core tests abort in a generic clock sleep

## Steps to reproduce

Run the complete enhanced Core and temporary-file suites in release mode with the five published dependency layers. Enable `swift.enable_testing` for test commands so internal Core imports compile. The retained failing invocation is `2eb445f9-5dd5-42d1-9b76-786c4a28e726` at source `6b128a0b696e3374cc25e44a5950b6dbc31bc34c`.

## Problem description

The temporary-file suite passes. Core aborts with `freed pointer was not the last allocation`; its crash report identifies `swift_task_dealloc` in the async resume of `pendingOperationTask()`, which calls generic `Task.sleep(for:)`. This matches the failure pattern described in [Swift issue 86204](https://github.com/swiftlang/swift/issues/86204). The exact compiler specialization collision has not been independently proved.

Compose already uses `ComposeTaskSleep` to avoid that specialization while retaining throwing cancellation behavior. Remaining direct Core test calls and three production deadline/polling calls still use the affected API. Route them through the existing wrapper without changing their durations, assertions, cancellation handling or runtime policies.

## Environment and evidence

The local Apple silicon run uses Swift 6.4 and optimized modules with immutable published dependency imports. Raw output, source identity, the failed test invocation and the crash report remain under `candidate-compose-attached-output/core-units-v1` and `core-crash-v1` in the retained performance programme. No historical baseline was rebuilt or rerun. The failed process is the test executable; host workers and the owned Bazel server were restored.

## Status

The directly identified test-helper path and the remaining production call sites are corrected. Complete optimized Core validation and affected stock runtime tests remain required. See [the companion change record](PR-optimized-clock-sleep.md).
