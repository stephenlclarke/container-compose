<!-- markdownlint-disable MD013 -->

# feat(events): support Compose event time filters

## Summary

- Enable `container compose events --json --since ... --until ... [SERVICE...]`.
- Pass parsed event time bounds through `ContainerEventOptions` to the fork-backed runtime event stream.
- Extend the optional local-only Docker Compose V2 parity check with a filtered event replay window.

## Type Of Change

- [x] New feature
- [ ] Bug fix
- [ ] Breaking change
- [x] Documentation update

## Motivation And Context

Docker Compose supports `events --since` and `events --until` by forwarding time filter strings to the Docker engine event stream. The first `container-compose` events slice kept those flags rejected because the runtime event stream was live-only.

The local `apple/container` fork now has a separate PR-shaped primitive for bounded event replay and time filtering. This PR is the Compose-side mapping: parse Docker-compatible time values, pass typed dates to the runtime, and leave Compose-specific filtering/output policy in this repository.

## Source And Dependency Decisions

- **Base issue:** [apple/container#484](https://github.com/apple/container/issues/484) remains the upstream event-stream anchor.
- **Runtime dependency:** `PR-container-event-time-filters.md`, code commit `d0977b5a99ec7dfd4fdc9a3b5e50b36869451270`, adds `ContainerEventOptions` and bounded event replay/time filters.
- **Runtime prerequisite:** `PR-container-events-stream.md`, code commits `b71e4bb323e3` and `0da7890b2632`, adds the first event stream.
- **No lower-runtime dependency:** no `apple/containerization` change is required.
- **Not based on Docker Compose code:** Docker Compose is used as behavioral guidance only; its Go engine-event implementation is not a source-code base for this Swift plugin.

## Commit Tracking

- Compose code commit to squash:
  - `3a3387d7dbea301eec3a7f1fcc3f954dec80276c feat(events): support compose event time filters`
- Follow-up Compose text-format commit:
  - `fd3d94824f23cd3255a812faed9e3972906b4ab5 feat(events): support compose text events`
  - `4cfb39e9531a84b496e1dcc76a84ac7654df943f fix(events): match compose text event timestamps`
- Container runtime dependency commit:
  - `d0977b5a99ec7dfd4fdc9a3b5e50b36869451270 feat(events): add event time filters`
- Container event-stream dependency commits:
  - `b71e4bb323e3 feat(events): stream container lifecycle events`
  - `0da7890b2632 fix(events): avoid blocking slow event subscribers`
- Lower runtime code commit: not required

Use the Compose code commit as one future `container-compose` PR. Keep it stacked after the Apple runtime time-filter PR; do not squash it into the Apple PR. Keep the text-format follow-up as its own later Compose PR.

## Implementation Details

- Updates `ContainerEventsAPIClienting` and `ContainerEventsManaging` to carry `ContainerEventOptions`.
- Parses `ComposeEventsOptions.since` and `.until` with `ComposeTimeParser`, keeping Docker-shaped time strings in `container-compose` before passing typed dates through `ContainerEventOptions`.
- Leaves `--json` required in this slice; default text formatting is handled by the later `PR-compose-events-text-format.md` slice.
- Updates dry-run output to show the Compose-owned direct runtime read, `compose-runtime events --since ... --until ...`, instead of depending on an Apple CLI command shape.
- Extends focused tests to verify:
  - selected services plus time filters reach the event manager;
  - invalid time filters are rejected before runtime calls;
  - dry-run includes runtime time flags;
  - `ContainerClientEventsManager` passes `ContainerEventOptions` through to the API client.
- Extends `Tools/parity/check-compose-events.sh` to replay a bounded Docker Compose event window with `--since` / `--until`.

## Docker Compose Compatibility Notes

Supported on the fork-backed integration stack:

- `container compose events --json --since VALUE`
- `container compose events --json --until VALUE`
- `container compose events --json --since VALUE --until VALUE SERVICE...`
- RFC 3339 timestamps, Unix timestamps, and relative durations for time filters

Still out of scope:

- Default text event formatting in this repository is handled by the follow-up `PR-compose-events-text-format.md` slice.
- Persistent event history across API-service restarts
- Network, volume, image, health, and restart-policy metadata events beyond the container lifecycle transitions emitted by the runtime dependency

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'events|eventManagerFiltersRuntimeStreamToComposeJSONServiceEvents'
bash -n Tools/parity/check-compose-events.sh
git diff --check -- Sources/ComposeCore/ContainerEventsAdapter.swift Sources/ComposeCore/ComposeOrchestrator.swift Sources/ComposePlugin/ComposePlugin.swift Tests/ComposeCoreTests/ComposeOrchestratorTests.swift Tools/parity/check-compose-events.sh
```

Optional local Docker Compose V2 parity validation:

```sh
make docker-compose-events-parity
```

This optional parity target is not run by CI and should stay out of Apple-facing required checks.

## container-compose Checks

- [x] I updated `DOCKER-COMPOSE-PARITY.md` for runtime primitive changes.
- [x] I updated `STATUS.md` and `RESUME.md`.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I recorded source/reference issues and PRs, including why they were or were not used as a base.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.

## Remaining Risks

- Released upstream support still waits for accepted Apple runtime event-stream and event-filter APIs.
- The runtime replay cache is bounded and in-memory only; Docker daemon-style persistent event history is not part of this slice.
