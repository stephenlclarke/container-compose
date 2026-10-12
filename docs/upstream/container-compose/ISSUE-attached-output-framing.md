# Attached output repeatedly scans and copies unfinished lines

## Problem

The published five-trial bounded matrix records median durations of 1.438115292 seconds for `logging-throughput-stdout-1m` and 2.166619958 seconds for `logging-dual-cache-delivery`, compared with historical Docker medians of 0.245255750 and 0.602509375 seconds respectively. These whole-command measurements identify candidates for investigation; they do not establish how much time the renderer contributes.

The renderer searches the entire unfinished tail on every chunk, mutates a dictionary-held `Data` copy, removes each completed line separately, and invokes the output hook per line. Large partial lines and dense multiline chunks therefore repeat avoidable work.

## Required behavior

Preserve exact concatenated bytes, one prefix per logical line, split LF/CRLF handling, binary payloads, timestamps, independent stream tails and stdout-before-stderr final flushing. Deliver callbacks outside the state lock in queue order, including direct and synchronous cross-thread callback reentry. Callback segmentation is unspecified.

## Acceptance and evidence

The captured maintained component passes ten focused logical tests, including four prefix/color parameter combinations, with 108 of 110 executable renderer lines covered (98.18%). The immutable capture used the older main checkout; the patch is now applied to the newer Bazel workflow lineage used for the published baseline. Full layered consumer tests and current-candidate runtime measurements remain required on that exact immutable source. The first report harness expected the XCTest XML filename; its original failed receipt is preserved alongside a read-only correction verifying the existing Swift Testing XML, without rerunning tests.

Reuse the published baseline binaries and all twenty historical timing samples for these two fixtures. Run only the changed candidate at the original five-trial, 4-GiB Colima, 200-MiB service profile with the authenticated frozen fixtures. Retain failures, exact source/runtime/fixture fingerprints, cleanup and restoration evidence. Do not infer a renderer-only causal speedup from whole-command results or replace broader programme gates with this focused slice.

## Status

Implementation and focused captured proof are complete. Layered consumer qualification, runtime measurements and candidate publication are pending. See [the companion change record](PR-attached-output-framing.md).
