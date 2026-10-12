# fix(runtime): consume direct XPC response deadlines

## Motivation and Context

An optimized runtime consumer crashes before the attached-output performance workload. See the [issue handoff](ISSUE-xpc-response-deadline-consumption.md) and [Swift compiler issue #86204](https://github.com/swiftlang/swift/issues/86204).

## Changes and Compatibility

Pin the narrowly patched Container client and seal its optimized SDK archive. Preserve ArgumentParser, Foundation, Containerization and Engine API published archive/evidence identities. No protocol, runtime, guest, fixture or historical benchmark is replaced. The changed client SDK is explicitly a new layer, not the byte-identical original layer set. Local mirror consumption is development evidence until the same qualified archive is published and download-verified.

## Validation

- Focused optimized XPC: 28 cases, no failures or skips, 22.126 seconds; exact changed source/test bytes retained in `xpc-units-v1`.
- Changed client SDK producer: 71.108 seconds, clean source, sealed archive; `xpc-sdk-produce-v1/acceptance.json` passes.
- Optimized source-mode CLI smoke and contracts: both pass, 40.377 seconds, with all four lower archives unchanged.
- Optimized prebuilt-layer runtime preflight and candidate-only logging timings remain pending.

Historical baseline binaries and measurements are reused without rebuilding or rerunning. The failing optimized consumer and recovery receipts remain intact. This does not establish full Compose or Docker parity; full Core and newest-stack integration remain separate pending gates.
