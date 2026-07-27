# Pull Request: sample container stats concurrently

## Summary

- Fan out each stats sample across running containers with a Swift task group.
- Restore deterministic container-list order using indexed results.
- Preserve first-sample omission and second-sample fallback behavior.

## Intended Review Delta

Apply signed commit `600fde28de94093fc5a067e19a29358a9adcec9e`
(`perf(stats): sample containers concurrently`) from
`stephenlclarke/container`.

The companion report is
[ISSUE-stats-concurrent-sampling.md](ISSUE-stats-concurrent-sampling.md), and
the originating upstream report is
[apple/container#2022](https://github.com/apple/container/issues/2022).

## Code Map

- `Sources/ContainerCommands/Container/ContainerStats.swift`: samples running
  containers through one ordered concurrent compact-map helper.
- `Tests/ContainerCommandsTests/ContainerStatsCommandTests.swift`: proves
  actual overlap, stable order, and failed-result compaction.

## Validation

```console
swift test --disable-automatic-resolution \
  --filter ContainerStatsCommandTests
make coverage-unit
make check
CONTAINER_STACK_REPO=/absolute/path/to/container \
  CONTAINERIZATION_INIT_SOURCE_PATH=/absolute/path/to/containerization \
  make docker-compose-parity
```

The focused concurrency regression passes and observes more than one active
operation while returning the original successful-input order. Complete
coverage and Compose v2 parity are required before publication.

## Compatibility and Risks

- Only snapshots with running status are scheduled, as before.
- A failed first sample still removes that container from output.
- A failed second sample still retains the first sample for both points.
- Result ordering remains the order returned by the container list.
- The runtime client already supports independent async requests; no server or
  public API changes.
- No Windows path or Linux guest behavior changes.

## Handoff Status

No Apple remote has been pushed. This change is independent of build and disk
usage performance work from the same upstream report.
