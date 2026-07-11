<!-- markdownlint-disable MD013 -->

# Feature request: add replay and time filters to container events

Related issue: [apple/container#484](https://github.com/apple/container/issues/484).

## Feature Or Enhancement Request Details

`apple/container` now has a local fork-backed first event-stream slice for [apple/container#484](https://github.com/apple/container/issues/484), but higher-level callers also need bounded replay and time filtering so `container events --since ... --until ...` and `container compose events --json --since ... --until ...` can avoid polling or client-side event history.

Docker Compose passes event filters through to the Docker engine event API as `Since` and `Until` strings. The engine can return historical events in that requested window and stop streaming at the upper bound. A matching Apple primitive should keep those semantics in the generic runtime event stream rather than making every client maintain a separate event cache.

## Existing Source And Stacking Decision

Use [apple/container#484](https://github.com/apple/container/issues/484) as the upstream issue anchor rather than opening a duplicate top-level event-stream request. This slice should stack on the local event-stream primitive documented in `docs/upstream/events/ISSUE-container-events-stream.md` / `docs/upstream/events/PR-container-events-stream.md`.

The current adjacent upstream work is separate from event replay and time filtering:

- [apple/container#286](https://github.com/apple/container/issues/286) and [apple/container#1258](https://github.com/apple/container/pull/1258) cover restart policy behavior, not event replay.
- [apple/container#378](https://github.com/apple/container/issues/378) and [apple/containerization#735](https://github.com/apple/containerization/issues/735) cover attach / PTY re-attach, not event replay.
- [apple/container#1756](https://github.com/apple/container/issues/1756), [apple/container#1777](https://github.com/apple/container/pull/1777), and [apple/container#1782](https://github.com/apple/container/pull/1782) cover graceful-stop diagnostics, not event filtering.

Those items are references for the wider lifecycle slab, but none is an implementation base for this time-filter slice.

## Proposed Runtime Requirements

- Add a typed `ContainerEventOptions` model with optional `since` and `until` dates.
- Preserve source compatibility by keeping `ContainerClient.events()` callable through default options.
- Store a bounded in-memory event history in the API-service event broadcaster.
- Replay buffered events that match `since` / `until` when a subscriber connects.
- Apply the same time filters to live events.
- Close a filtered stream once its `until` bound has elapsed.
- Expose `container events --since` and `container events --until` as CLI conveniences around those typed bounds.
- Keep the cache API-service-lifetime only. Persistent event journaling should be a later design discussion if maintainers want behavior beyond an in-memory bounded replay.
- Keep Compose project/service filtering, selected-service arguments, one-off suppression, JSON shape, and label stripping out of `apple/container`.

## Docker And Docker Compose Guidance

- Docker Compose docs: <https://docs.docker.com/reference/cli/docker/compose/events/>
- Docker engine events docs: <https://docs.docker.com/reference/cli/docker/system/events/>
- Docker Compose command source: <https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/cmd/compose/events.go>
- Docker Compose backend source: <https://github.com/docker/compose/blob/9b55a6e9c1016fd3c31859b7e09260378d45a783/pkg/compose/events.go>

Docker Compose exposes `--since` and `--until` as strings and forwards them to `EventsListOptions`. The Apple runtime API should use typed dates at the Swift boundary. `container-compose` owns Docker-compatible timestamp parsing before it calls that API; the Apple CLI can keep any native parser it needs for `container events`.

## Acceptance Criteria

- `ContainerClient.events(options:)` can replay matching recent lifecycle events from the bounded API-service cache.
- `container events --since 2026-06-22T10:00:00Z --until 2026-06-22T10:05:00Z` passes typed dates over XPC and closes once the upper bound is reached.
- Existing `ContainerClient.events()` callers keep their original live-stream behavior.
- Tests cover option encoding, broadcaster replay, live filtering, history bound behavior, XPC decoding, and CLI timestamp parsing.

## Code Of Conduct And Documentation

- [x] I agree to follow this project's Code of Conduct.
- [x] This draft references the existing upstream issue instead of opening a duplicate.
- [x] I checked current Apple issues and PRs before selecting this slice.
- [x] I recorded adjacent issues/PRs and why they were not chosen as implementation bases.
