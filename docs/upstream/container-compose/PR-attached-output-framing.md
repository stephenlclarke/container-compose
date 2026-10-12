# perf(logs): frame attached output incrementally and batch callbacks

## Resulting behavior

Foreground attached output retains its exact bytes and formatting while unfinished lines are scanned only for newly received bytes. Each stream buffer is removed from the dictionary before mutation, completed lines are rendered into one append batch, and the consumed buffer prefix is removed once.

A single queue drainer serializes callbacks outside the state lock. Reentrant and concurrent producers enqueue without waiting for a callback that may depend on them. Consumed data buffers are released during draining. In the attachment flow, the drainer-owning append remains synchronous through drain completion before the attachment task finishes. The hook documentation and orchestration assertion explicitly treat callback chunk boundaries as unspecified.

## Validation

The retained focused capture passes ten logical Swift Testing cases, including four prefix/color parameter combinations: a line over one mebibyte in uneven chunks, two thousand lines in one append, split CRLF and LF, blank and binary lines, record and current timestamps, interleaved streams and final tails, direct and cross-thread reentry, concurrent delivery, empty chunks, successive tails and sliced `Data` with nonzero indices. Instrumented renderer line coverage is 98.18% (108/110). The raw report-name harness failure and corrected read-only verification are both retained; no passing tests were rerun to repair reporting.

An independent final review found no remaining actionable issue after replacing a condition-variable wait that could deadlock across a callback's delegated append. The [immutable diagnostic candidate](https://github.com/stephenlclarke/container-compose/releases/tag/candidate-output-performance-b89eecd3379b-f7da9cbca159) passes the three original five-trial logging workloads and stores exact binaries, raw timings, parity results and provenance. Its stdout median improves 33.4% against the recorded fork; delivery and cached reads are effectively unchanged. Whole-command timings do not isolate renderer cost. The corrected follow-on source `e2aa25f059979e3a9a9060e192bf4ad5ff4740fa` passes all 1,310 enhanced Core and eight temporary-file cases and builds a new signed upper candidate. The [follow-on full logging candidate](https://github.com/stephenlclarke/container-compose/releases/tag/candidate-output-performance-e2aa25f05997-ba07cf8d6891) records all 110 successful observations across the 22 frozen workloads. Its 1-MiB stdout median improves 26.6% against the original fork, but is slower than the earlier focused candidate; attached startup is 14.7% slower than the original fork and 6.34 times Docker. All raw rows and regressions are retained. No unchanged baseline has been rebuilt or remeasured.

## Compatibility and remaining scope

There is no CLI/configuration change. Consumers must concatenate callback chunks rather than assume one callback per line. A slow callback can queue output from concurrent producers; delivered data buffers are released promptly. Published historical whole-command timings are reused and do not isolate renderer cost. Newest Container/Containerization stack integration and programme-wide gates remain separate pending requirements.

See [the companion issue](ISSUE-attached-output-framing.md).
