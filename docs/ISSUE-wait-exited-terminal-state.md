# Wait rejects naturally exited native containers

## Steps to reproduce

Start a finite service, let it finish naturally, then run `compose wait SERVICE` or `compose wait --down-project SERVICE` with the matched native client/runtime. The native discovery adapter deliberately reports a runtime `stopped` container with a recorded start date as `exited`.

## Problem description

The retained current-native performance run recorded eight successful logging samples, then failed while waiting for the logger after `logging-blocking-slow-sink`. `stoppedWaitExitCode` accepted only `stopped`, so it rejected a truthful `exited` state instead of replaying the stored exit code. Host, runtime and Colima restoration passed; the failed run remains preserved. No historical baseline is rerun or reclassified.

Both terminal states should return the actual stored exit code, including zero and nonzero results. A missing code must still fail with the actual reported status. `created` and unknown states must remain unsupported, even if a code is present. Running/stopping targets must still call runtime wait; `--down-project` must not tear down a live target before that wait completes.

## Environment and scope

Observed product: compiled Compose `49e80ae625ba023ddfcfddf31848eec1d44e6a00`, component source `e8133a16d70ec563f45b78dc3eba99ec5cdbdd09`, Container `fc5d94aeeaae2ce373480a65b7a7ae11c2897315`, SDK `518f92a006c94c55e21422f3cf2f93c2f039d053`. The correction belongs to shared Compose wait orchestration, not native state projection, discovery identity, runtime behavior or the frozen workload.

## Completion and remaining proof

The narrow change and parameterized regressions are implemented. Source-only formatting, lint and documentation checks are permitted locally; optimized native Core tests, recompilation and fresh current-candidate timing remain root-owned pending gates. No successful new runtime or performance claim is made. See [the matching PR handoff](PR-wait-exited-terminal-state.md).
