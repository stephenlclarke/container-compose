# Performance: container stats samples running containers serially

## Summary

`container stats` previously requested both samples one container at a time.
Each slow runtime request therefore added directly to command latency even
though containers are independent sampling targets.

This reproduces the third performance finding in
[apple/container#2022](https://github.com/apple/container/issues/2022).

## Reproduction on macOS

1. Start several containers.
2. Run a one-shot `container stats --no-stream`.
3. Observe or profile the runtime requests; both the first and second sample
   loops await every container serially.

## Expected behavior

Sample running containers concurrently while preserving list order and the
existing failure behavior: omit a container whose first sample fails, and keep
its first sample if only its second sample fails.

## Ownership and boundary

This is generic `container stats` command behavior in `apple/container`.
Compose should consume the runtime's ordinary stats surface without adding
runtime-specific fan-out.

## Commit tracking

- `600fde28de94093fc5a067e19a29358a9adcec9e` —
  `perf(stats): sample containers concurrently`.

## Validation expectations

- Prove that more than one transform is active concurrently.
- Prove deterministic input ordering after concurrent completion.
- Prove that failed first samples are compacted.
- Run the complete Container unit and coverage gates.
- Confirm Compose v2 stats-model parity remains unchanged.
