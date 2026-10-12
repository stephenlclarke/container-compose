# Attached output repeatedly scans and copies unfinished lines

## Problem

The published five-trial bounded matrix records median durations of 1.438115292 seconds for `logging-throughput-stdout-1m` and 2.166619958 seconds for `logging-dual-cache-delivery`, compared with historical Docker medians of 0.245255750 and 0.602509375 seconds respectively. These whole-command measurements identify candidates for investigation; they do not establish how much time the renderer contributes.

The renderer searches the entire unfinished tail on every chunk, mutates a dictionary-held `Data` copy, removes each completed line separately, and invokes the output hook per line. Large partial lines and dense multiline chunks therefore repeat avoidable work.

## Required behavior

Preserve exact concatenated bytes, one prefix per logical line, split LF/CRLF handling, binary payloads, timestamps, independent stream tails and stdout-before-stderr final flushing. Deliver callbacks outside the state lock in queue order, including direct and synchronous cross-thread callback reentry. Callback segmentation is unspecified.

## Acceptance and evidence

The captured maintained component passes ten focused logical tests, including four prefix/color parameter combinations, with 108 of 110 executable renderer lines covered (98.18%). The immutable capture used the older main checkout; the patch is now applied to the newer Bazel workflow lineage used for the published baseline. Follow-on enhanced layered Core and full logging evidence is recorded below; the separately published stock Engine test-support supplement passes 110 cases; newest-stack qualification remains open. The first report harness expected the XCTest XML filename; its original failed receipt is preserved alongside a read-only correction verifying the existing Swift Testing XML, without rerunning tests.

Reuse the published baseline binaries and all twenty historical timing samples for these two fixtures. Run only the changed candidate at the original five-trial, 4-GiB Colima profile (200-MiB lifecycle and aggregate services; other logging fixtures uncapped) with the authenticated frozen fixtures. Retain failures, exact source/runtime/fixture fingerprints, cleanup and restoration evidence. Do not infer a renderer-only causal speedup from whole-command results or replace broader programme gates with this focused slice.

## Status

Implementation and focused captured proof are complete. The scoped optimized consumer and three five-trial runtime workloads pass, and their immutable diagnostic candidate is published with binary, parity, benchmark and provenance assets. Corrected follow-on source also passes all 1,318 enhanced Core and temporary-file cases; all 110 observations across the 22 frozen logging workloads pass and are stored in the [follow-on diagnostic release](https://github.com/stephenlclarke/container-compose/releases/tag/candidate-output-performance-e2aa25f05997-ba07cf8d6891). Newest-stack integration, performance parity and notarized product qualification remain pending. The [complete frozen timing evidence](https://github.com/stephenlclarke/container-compose/releases/tag/evidence-compose-fullmatrix-e2aa25f05997-241aeaed9cc0) completes the original 26-workload matrix with 130 candidate observations: 110 published logging observations reused unchanged and 20 new startup/teardown observations. All original contracts and timing guards pass. One-service startup is 4.82 times the recorded Docker median; ten-service startup is 2.78 times Docker. One-service teardown is effectively level with Docker. Raw timings, derived JUnit, lifecycle restoration evidence and exact binary references are release assets. No binary or historical baseline was rebuilt or rerun. The [published stock test-support supplement](https://github.com/stephenlclarke/container-compose/releases/tag/layer-stock-test-support-98b68198dab0-02020d464b67) separately passes 110 stock Engine component cases; its original controller failure and authenticated recovery are preserved. Lifecycle timing proves the original command-success contract, not broader CRUD semantics. Newest-stack integration, Docker performance parity, measured overall coverage and notarized product qualification remain open.

See [the companion change record](PR-attached-output-framing.md).
