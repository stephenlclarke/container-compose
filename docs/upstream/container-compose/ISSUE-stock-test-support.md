# Published client layers omit the stock Engine server fixture

## Steps to reproduce

Run `//:ComposeEngineRuntimeTests` in optimized stock mode against the five published product layers. The full prebuilt attempt fails analysis because `ContainerUnixHTTPServer` has no imported providers. A foundation-only attempt fails because the server's `NIOWebSocket` dependency is absent. Neither executes a test case.

## Problem description

The product's client closure correctly excludes unused server libraries. Tests need a separate supplement rather than a product-layer rebuild or an implicit source fallback. The exact configured graph identifies three missing targets: `ContainerUnixHTTPServer.rspm.__impl`, `NIOWebSocket.rspm.__impl` and `CNIOSHA1.rspm_c`. Existing published modules must remain byte-identical.

## Environment and evidence

Apple silicon, Swift 6.4, pinned Bazel 8.8, optimized stock configuration and minimum macOS 15.0. Analysis failures and original logs are retained in the performance programme's `candidate-compose-attached-output/core-units-v2` and `stock-engine-units-v1` directories. Source-graph discovery compiles nothing. The existing enhanced Core and frozen logging evidence remain separate passing gates.

## Required result

Authenticate current source, toolchain, five published archives and configured dependency variants. Build only missing fixture libraries in an isolated producer, seal their binary delta, and execute the stock Engine suite in a separate import-only consumer. Preserve fresh test XML/log, positive case counts and successful owned-server cleanup. Reject source or input drift, archive overwrites, cached test execution and any unlisted lower compilation. See the [change record](PR-stock-test-support.md).

## First isolated attempt

Source `d7b8ca2c319b16a743d5ba9320e21b64eead0e12` stops before compilation because the freshly generated `.build/.lock` in Swift Atomics differs from its archived copy. The offline overlap scan identifies exactly five such differences, all numeric SwiftPM process-ID files; every other overlapping metadata file matches. Generated package rules contain no reference to those files or globs that could consume them. The narrowly scoped correction preserves the authenticated archived lock bytes and records both hashes; any other differing metadata still fails. The failed attempt remains under `stock-test-support-v1`, with successful owned-server cleanup and host restoration. Native producer/consumer qualification remains pending.

Source `d7c0cb5821f69545bd168d9fc771b5f69204d171` builds the missing modules and the import-only consumer, then executes 110 stock tests. Its fixture setup records 105 issues because the harness's output-directory name lengthens Unix socket paths beyond macOS's limit. The correction uses the short enrolled SSD test root; Bazel's per-test temporary directory and the fixture's random suffix retain isolation. The failed `stock-test-support-v2` evidence and compiled outputs remain intact, with successful cleanup/restoration. The next attempt must prove successful execution and actual cache reuse; neither is inferred from the harness fix.

Source `98b68198dab03fb5103538592320036c8c161d8a` passes all 110 stock Engine cases, with no XML failures, errors or skips. The producer uses 50 disk-cache hits and 36 internal actions; the consumer uses three disk-cache hits, two internal actions and one fresh test execution. The controller still records failure because its validator incorrectly assumes a zero-based shard ID. Bazel emits shard 1 for the unsharded attempt. The corrected validator is tested against that actual event and rejects missing, zero or multiple shard IDs. Owned-server cleanup and host restoration pass. A separate retained-evidence recovery must authenticate and seal these passing outputs; the original failed controller receipt remains unchanged, and native tests are not rerun.

## Qualified test-only result

The [immutable supplement](https://github.com/stephenlclarke/container-compose/releases/tag/layer-stock-test-support-98b68198dab0-02020d464b67) now contains the seven binary files for the exact three missing targets, the 110-case passing JUnit report, raw evidence, provenance and the reviewed recovery processor. Retained-evidence validation at `987f3eb8` authenticates executed source `98b68198`, configured graph variants, all five unchanged product archives, producer/consumer input identities, successful build/test events, exact imported bytes, cleanup and host restoration. No fourth native execution was performed. The original failed controller receipt remains unchanged. The archive and all five published asset digests are download-verified; this resolves the missing stock test-fixture closure only. Coverage, newest-stack integration, live/performance parity and product qualification remain separate open gates.
