# Support `compose up` Attach Log Selection

## Summary

`container compose up --attach SERVICE` and `container compose up --attach-dependencies` should be accepted for attached `up` runs and should follow the selected service logs after starting the selected project graph.

The plugin already supports `up --no-attach`, raw attached output flags, and timestamped log follow. The remaining Compose-side gap is accepting Docker Compose's positive attach selectors and applying them to the log streams that follow an attached `up` run.

## Acceptance Criteria

- `container compose help up` shows `--attach` and `--attach-dependencies` as supported.
- `up --attach SERVICE` validates selected services and follows only the requested service log targets.
- `up --attach SERVICE --attach-dependencies` also follows dependency service log targets that are part of the selected start graph.
- Attached-log mode starts selected service containers detached before following logs, so multiple log targets can be multiplexed through the existing runtime log stream.
- `--attach` combined with a service outside the selected start graph fails before runtime side effects.
- Focused unit tests cover selected attach logs, dependency attach logs, validation, and CLI help/parser support.
- A compose.yml dry-run runtime smoke proves the generated runtime commands include the expected detached starts and followed log streams.

## Notes

This is a Compose-side change. It reuses the direct runtime log follower already used by `compose logs --follow` and does not require new apple/container APIs.
