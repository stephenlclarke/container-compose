# fix(runtime): consume direct XPC response deadlines

## Motivation and Context

An optimized runtime consumer crashes before the attached-output performance workload. See the [issue handoff](ISSUE-xpc-response-deadline-consumption.md) and [Swift compiler issue #86204](https://github.com/swiftlang/swift/issues/86204).

## Changes and Compatibility

Pin the narrowly patched Container client and seal its optimized SDK archive. Preserve ArgumentParser, Foundation, Containerization and Engine API published archive/evidence identities. The strict matching-stack check requires a newly built runtime from the same patched source. Protocol, guest, builder, fixtures and historical benchmarks are unchanged. The changed client SDK is explicitly a new layer, not the byte-identical original layer set. The SDK archive is published and download-verified as `layer-container-sdk-enhanced-66d87a93c4747679463f`; the final Compose build consumes that release.

## Validation

- Focused optimized XPC: 28 cases, no failures or skips, 22.126 seconds; exact changed source/test bytes retained in `xpc-units-v1`.
- Changed client SDK producer: 71.108 seconds, clean source, sealed archive; `xpc-sdk-produce-v1/acceptance.json` passes.
- Optimized source-mode CLI smoke and contracts: both pass, 40.377 seconds, with all four lower archives unchanged.
- Optimized prebuilt-layer runtime preflight passes with matching client/runtime `641b7019`; all 15 candidate-only logging trials pass with 65,536 ordered unique delivery/cache records per trial and exact cleanup inventories.
- Stdout whole-command median improves 33.4% versus the retained fork, to 0.957 seconds; it is still 3.90 times the recorded Docker median. Remote delivery (+0.11%) and cached reads (+0.97%) are effectively unchanged. Five historical observations are diagnostic, not simultaneous paired measurements or renderer-only causality.
- The [immutable diagnostic candidate](https://github.com/stephenlclarke/container-compose/releases/tag/candidate-output-performance-b89eecd3379b-f7da9cbca159) retains signed Compose/runtime binaries, raw timings, semantic assertions and provenance. The archives are not notarized and full qualification is false.
- Restoration preserves the original failing Homebrew API service registration; it does not repair that pre-existing service failure.

Historical baseline binaries and measurements are reused without rebuilding or rerunning. The failing optimized consumer and recovery receipts remain intact. This does not establish full Compose or Docker parity; full Core and newest-stack integration remain separate pending gates.
