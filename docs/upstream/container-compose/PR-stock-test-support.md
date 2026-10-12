# test(bazel): qualify a separate stock server fixture supplement

## Resulting behavior

An opt-in local gate derives the missing stock test-fixture closure from the exact configured graph. Its isolated producer imports all existing published modules and compiles only missing package targets; its consumer imports all libraries and runs the actual stock Engine component suite. Original package wrappers, dependency edges and minimum-OS transitions remain intact. Five current product archive hashes and locks remain unchanged.

## Validation

Offline admission regressions cover archive safety, graph derivation, overwrite rejection, import-only composition, configuration drift, prohibited lower compilation, generated-workspace identity, owned command selection and fresh test evidence. Source-graph discovery found exactly the three targets recorded in the [issue](ISSUE-stock-test-support.md). The actual producer/consumer qualification is pending; offline success is not evidence that native compilation or Engine test execution passes. Failed prior product-only analysis attempts remain retained.

The first isolated attempt at `d7b8ca2c` fails before compilation on a SwiftPM process-ID lock collision. All five differing `.build/.lock` files are recorded separately from build inputs; no other overlapping metadata differs. The follow-on admission exception accepts only an unreferenced exact process-ID lock path, preserves archived bytes, and retains both hashes. Successful owned-server cleanup and host restoration are recorded; the failed attempt is not relabeled as passing.

The second attempt at `d7c0cb58` builds both producer and import-only consumer and executes 110 tests, then fails fixture setup at macOS's Unix socket path limit. The helper now selects the short enrolled SSD temporary root while keeping Bazel/fixture isolation. A regression checks the actual invocation flag and socket layout against the limit. The shared compiled-output cache remains configured; fresh successful test execution and measured cache reuse remain pending.

## Compatibility and remaining risks

Product recipes and pins are unchanged. The new supplement is test-only and cannot replace a product dependency. It is sealed only after successful fresh component execution and source/archive revalidation. This gate does not establish live Docker parity, performance parity, newest-stack integration, notarization, coverage or release readiness. The existing enhanced Core and published logging proof are reused without rerunning unchanged workloads.

## Linked records

See the [operator workflow](../../guides/BAZEL.md#stock-engine-test-support-supplement) and [optimized sleep correction](PR-optimized-clock-sleep.md). No Apple issue or pull request is created by this change.
