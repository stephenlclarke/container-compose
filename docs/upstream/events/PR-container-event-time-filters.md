<!-- markdownlint-disable MD013 -->

# feat(events): add event time filters

Related issue: [apple/container#484](https://github.com/apple/container/issues/484).

## Summary

- Add `ContainerEventOptions(since:until:)` to the runtime event API.
- Keep a bounded API-service event history so new subscribers can replay recent matching events.
- Add `container events --since` and `container events --until` using the existing Docker-compatible timestamp parser.

## Type Of Change

- [x] New feature
- [ ] Bug fix
- [ ] Breaking change
- [x] Documentation update

## Motivation And Context

The first event-stream slice for [apple/container#484](https://github.com/apple/container/issues/484) exposes live lifecycle events. Docker-compatible clients also need time-windowed replay for `--since` and `--until`; otherwise higher-level callers such as `container-compose` must either reject those flags or maintain their own event cache.

This PR is intentionally a second Apple-shaped primitive stacked on the event stream PR. It keeps event history and time filtering in `apple/container`, while `container-compose` keeps project/service filtering, selected services, one-off suppression, and Docker Compose JSON formatting.

## Source And Dependency Decisions

- **Base issue:** [apple/container#484](https://github.com/apple/container/issues/484) remains the upstream event-stream request.
- **Runtime dependency:** this PR stacks on `PR-container-events-stream.md` and requires its constructible code commits `b71e4bb323e3` and `0da7890b2632`.
- **No lower-runtime dependency:** no `apple/containerization` change is required because the cache and filters sit at the API-service event stream boundary.
- **Not based on Docker Compose code:** Docker Compose source is Go code over Docker engine events. This PR uses Docker behavior as the compatibility contract and keeps the Swift runtime API typed.
- **Adjacent lifecycle PRs not used:** restart-policy, attach, and graceful-stop PRs are unrelated to event replay and should remain separate review conversations.

## Commit Tracking

- Container code commit to squash:
  - `d0977b5a99ec7dfd4fdc9a3b5e50b36869451270 feat(events): add event time filters`
- Container dependency commits:
  - `b71e4bb323e3 feat(events): stream container lifecycle events`
  - `0da7890b2632 fix(events): avoid blocking slow event subscribers`
- Compose mapping commit:
  - `3a3387d7dbea301eec3a7f1fcc3f954dec80276c feat(events): support compose event time filters`
- Lower runtime code commit: not required

Use `d0977b5a99ec7dfd4fdc9a3b5e50b36869451270` as one future upstream `apple/container` PR stacked after the event-stream PR. Do not squash the Compose mapping into this Apple runtime PR.

## Implementation Details

- Adds `ContainerEventOptions` with optional `since` and `until` dates.
- Updates `ContainerClient.events(options:)` with `.default` options so existing callers keep source-compatible behavior.
- Adds XPC keys `eventSince` and `eventUntil`.
- Updates `ContainersHarness` to decode event options from the XPC message.
- Updates `ContainerEventBroadcaster` to:
  - store a bounded in-memory history, currently 1,024 events by default;
  - replay matching history to new subscribers;
  - filter live events per subscriber;
  - close stale subscribers when the `until` bound has passed;
  - retain the non-blocking writer behavior for slow subscribers.
- Adds `container events --since` and `container events --until` flags.
- Reuses `ContainerLogTimestampParser` so log and event filters accept the same Docker-compatible RFC 3339, Unix timestamp, and relative-duration inputs.

## Docker Compose Compatibility Notes

This PR makes the runtime capable of supporting:

- `container events --since ...`
- `container events --until ...`
- `container compose events --json --since ... --until ...` through the separate Compose mapping PR

It remains intentionally limited:

- Replay is bounded and in-memory only.
- API-service restart loses historical event history.
- Network, volume, image, health, and restart-policy metadata events remain future event-source work.
- Human-readable event formatting remains outside this runtime primitive.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter ContainerEvent
swift format lint --strict --configuration .swift-format-nolint Sources/ContainerResource/Container/ContainerEventOptions.swift Sources/Services/ContainerAPIService/Client/XPC+.swift Sources/Services/ContainerAPIService/Client/ContainerClient.swift Sources/Services/ContainerAPIService/Server/Containers/ContainerEventBroadcaster.swift Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift Sources/Services/ContainerAPIService/Server/Containers/ContainersHarness.swift Sources/ContainerCommands/Container/ContainerEvents.swift Tests/ContainerResourceTests/ContainerEventTests.swift Tests/ContainerAPIServiceTests/ContainerEventBroadcasterTests.swift Tests/ContainerCommandsTests/ContainerEventsCommandTests.swift
```

Planned pre-PR validation:

```sh
swift build --product container --product container-apiserver
git diff --check
markdownlint ISSUE-container-event-time-filters.md PR-container-event-time-filters.md
```

## Maintainer Review Notes

- The bounded replay cache is deliberately small and local to the API-service event broadcaster. A persistent event journal would need a separate storage and retention discussion.
- The Swift API takes typed `Date` values; Docker-compatible string parsing stays in CLI/client layers.
- Compose-specific labels are carried as ordinary container labels, but no Compose filtering or output policy is added here.
