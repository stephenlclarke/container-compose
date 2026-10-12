# Optimized Compose response deadlines abort before measurement

## Problem

The signed attached-output candidate `085da2fb9e9a0f62b56ddb546b001f64c36e55f8` aborts in the timeout task resume frame of Container XPC. The same optimized CLI smoke/contracts passed, so those checks alone did not establish runtime readiness. The retained `measurement-v4` has zero timing samples; its separate `recovery-native-v2` receipt confirms original runtime and workers were restored.

## Reproduction and expected behavior

Build the optimized candidate with its original prebuilt layers, start the isolated published f86 runtime, and invoke the frozen one-service `compose up -d` preflight. The consumer reports `freed pointer was not the last allocation` and SIGABRT. XPC replies and deadlines should complete normally.

## Dependency and environment

Swift 6.4.0.34.1, Xcode 27.0, macOS 27, Apple silicon. The failing thunk is consistent with [Swift issue #86204](https://github.com/swiftlang/swift/issues/86204). A narrow client fix uses direct monotonic clock deadlines; the exact compiler allocation mismatch is not independently proved. This is a local dependency handoff, with no upstream submission.

## Scope

Select Container `641b7019ce11735e75b331e32a777a130439e9f3`, a timeout-only backport onto the frozen f86 SDK source. Rebuild that changed client archive and preserve all four lower archive/evidence hashes, the guest/runtime, fixture image, workloads and historical measurements. The current maintained Container branch also contains the same source fix; the backport isolates this benchmark change from unrelated dependency updates.
