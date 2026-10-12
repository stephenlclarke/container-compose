# Optimized Core tests abort in a generic clock sleep

## Steps to reproduce

Run the complete enhanced Core and temporary-file suites in release mode with the five published dependency layers. Enable `swift.enable_testing` for test commands so internal Core imports compile. The retained failing invocation is `2eb445f9-5dd5-42d1-9b76-786c4a28e726` at source `6b128a0b696e3374cc25e44a5950b6dbc31bc34c`.

## Problem description

The temporary-file suite passes. Core aborts with `freed pointer was not the last allocation`; its crash report identifies `swift_task_dealloc` in the async resume of `pendingOperationTask()`, which calls generic `Task.sleep(for:)`. This matches the failure pattern described in [Swift issue 86204](https://github.com/swiftlang/swift/issues/86204). The exact compiler specialization collision has not been independently proved.

Compose already uses `ComposeTaskSleep` to avoid that specialization while retaining throwing cancellation behavior. Remaining direct Core test calls and three production deadline/polling calls still use the affected API. Route them through the existing wrapper without changing their durations, assertions, cancellation handling or runtime policies.

## Environment and evidence

The local Apple silicon run uses Swift 6.4 and optimized modules with immutable published dependency imports. The existing wrapper documents its original Swift 6.2 workaround; the newly retained crash shows the same failure pattern on Swift 6.4. Raw output, source identity, the failed test invocation and the crash report remain under `candidate-compose-attached-output/core-units-v1` and `core-crash-v1` in the retained performance programme. No historical baseline was rebuilt or rerun. The failed process is the test executable; host workers and the owned Bazel server were restored.

## Status

The directly identified test-helper path and the remaining production call sites are corrected. Ten short sleeps in the stock foreground test helpers use the same workaround; their component execution now passes all 110 stock Engine cases through a separately qualified test-only closure. Source `e2aa25f059979e3a9a9060e192bf4ad5ff4740fa` passes all 1,310 enhanced Core cases and eight temporary-file cases in optimized mode. The original stock Engine gate stopped before any test because the published client-only binary closure omits the server fixture and its NIO WebSocket dependency. That failure is retained separately and does not invalidate the passing enhanced Core proof. The same source passes all 110 observations across the 22 frozen logging workloads, retained with raw timing and provenance in the [diagnostic release](https://github.com/stephenlclarke/container-compose/releases/tag/candidate-output-performance-e2aa25f05997-ba07cf8d6891). Stock test-support layering is now qualified separately; full stack qualification remains required. The [complete frozen timing evidence](https://github.com/stephenlclarke/container-compose/releases/tag/evidence-compose-fullmatrix-e2aa25f05997-241aeaed9cc0) completes the original 26-workload matrix with 130 candidate observations: 110 published logging observations reused unchanged and 20 new startup/teardown observations. All original contracts and timing guards pass. One-service startup is 4.82 times the recorded Docker median; ten-service startup is 2.78 times Docker. One-service teardown is effectively level with Docker. Raw timings, derived JUnit, lifecycle restoration evidence and exact binary references are release assets. No binary or historical baseline was rebuilt or rerun. The [published stock test-support supplement](https://github.com/stephenlclarke/container-compose/releases/tag/layer-stock-test-support-98b68198dab0-02020d464b67) separately passes 110 stock Engine component cases; its original controller failure and authenticated recovery are preserved. Lifecycle timing proves the original command-success contract, not broader CRUD semantics. Newest-stack integration, Docker performance parity, measured overall coverage and notarized product qualification remain open.

See [the companion change record](PR-optimized-clock-sleep.md).
