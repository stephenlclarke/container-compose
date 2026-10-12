# Published client layers omit the stock Engine server fixture

## Steps to reproduce

Run `//:ComposeEngineRuntimeTests` in optimized stock mode against the five published product layers. The full prebuilt attempt fails analysis because `ContainerUnixHTTPServer` has no imported providers. A foundation-only attempt fails because the server's `NIOWebSocket` dependency is absent. Neither executes a test case.

## Problem description

The product's client closure correctly excludes unused server libraries. Tests need a separate supplement rather than a product-layer rebuild or an implicit source fallback. The exact configured graph identifies three missing targets: `ContainerUnixHTTPServer.rspm.__impl`, `NIOWebSocket.rspm.__impl` and `CNIOSHA1.rspm_c`. Existing published modules must remain byte-identical.

## Environment and evidence

Apple silicon, Swift 6.4, pinned Bazel 8.8, optimized stock configuration and minimum macOS 15.0. Analysis failures and original logs are retained in the performance programme's `candidate-compose-attached-output/core-units-v2` and `stock-engine-units-v1` directories. Source-graph discovery compiles nothing. The existing enhanced Core and frozen logging evidence remain separate passing gates.

## Required result

Authenticate current source, toolchain, five published archives and configured dependency variants. Build only missing fixture libraries in an isolated producer, seal their binary delta, and execute the stock Engine suite in a separate import-only consumer. Preserve fresh test XML/log, positive case counts and successful owned-server cleanup. Reject source or input drift, archive overwrites, cached test execution and any unlisted lower compilation. See the [change record](PR-stock-test-support.md).
