<!-- markdownlint-disable MD013 -->

# feat(events): support Compose text events

## Summary

- Make `container compose events` render Docker Compose-style text by default.
- Preserve `container compose events --json` JSON Lines output.
- Extend the optional local-only Docker Compose V2 parity check with default text replay validation.

## Type Of Change

- [x] New feature
- [ ] Bug fix
- [ ] Breaking change
- [x] Documentation update

## Motivation And Context

Docker Compose defaults `events` to text output and only emits JSON when `--json` is passed. The previous local slices implemented the generic Apple runtime event stream, Compose JSON filtering/output, and time-filter mapping, but still treated non-JSON output as a follow-up.

This PR closes that Compose-owned presentation gap without adding Docker Compose policy to `apple/container`.

## Source And Dependency Decisions

- **Base issue:** no Apple issue is needed for this plugin-only formatting slice.
- **Runtime anchor:** [apple/container#484](https://github.com/apple/container/issues/484) remains the upstream runtime event-stream issue.
- **Runtime dependency:** `PR-container-event-time-filters.md`, code commit `d0977b5a99ec7dfd4fdc9a3b5e50b36869451270`, adds `ContainerEventOptions` and bounded event replay/time filters.
- **Runtime prerequisite:** `PR-container-events-stream.md`, code commits `b71e4bb323e3` and `0da7890b2632`, adds the first event stream.
- **Compose prerequisites:** `PR-compose-events.md`, code commit `113be38063ea`, and `PR-compose-event-time-filters.md`, code commit `3a3387d7dbea301eec3a7f1fcc3f954dec80276c`.
- **No lower-runtime dependency:** no `apple/containerization` change is required.
- **Docker Compose source use:** Docker Compose source is the behavioral reference for text output shape. The Swift implementation does not reuse Go code.

## Commit Tracking

- Compose code commit to squash:
  - `fd3d94824f23cd3255a812faed9e3972906b4ab5 feat(events): support compose text events`
- Compose dependency commits:
  - `113be38063ea feat(events): map compose events`
  - `3a3387d7dbea301eec3a7f1fcc3f954dec80276c feat(events): support compose event time filters`
- Container runtime dependency commits:
  - `b71e4bb323e3 feat(events): stream container lifecycle events`
  - `0da7890b2632 fix(events): avoid blocking slow event subscribers`
  - `d0977b5a99ec7dfd4fdc9a3b5e50b36869451270 feat(events): add event time filters`
- Lower runtime code commit: not required

Use the Compose code commit as one future `container-compose` PR. Keep it stacked after the Apple runtime event stream/time-filter PRs and the prior Compose event mapping PRs.

## Implementation Details

- Adds `ComposeEventsOutputFormat` with `.text` and `.json`.
- Makes `ComposeEventsOptions` choose text unless `--json` is passed.
- Passes the selected format through `ContainerEventsManaging`.
- Keeps the existing JSON Lines renderer for `--json`.
- Adds Docker Compose-style text rendering:
  - UTC timestamp in `YYYY-MM-DD HH:MM:SS.ffffff` shape;
  - `container ACTION CONTAINER`;
  - public attributes as `key=value` pairs.
- Sorts text attributes for deterministic output.
- Extends `Tools/parity/check-compose-events.sh` with optional Docker Compose text replay validation.

## Docker Compose Compatibility Notes

Supported on the fork-backed integration stack:

- `container compose events [SERVICE...]`
- `container compose events --since VALUE --until VALUE [SERVICE...]`
- `container compose events --json [SERVICE...]`
- `container compose events --json --since VALUE --until VALUE [SERVICE...]`

Still out of scope:

- Persistent event history across API-service restarts.
- Network, volume, image, health, and restart-policy metadata events beyond the container lifecycle transitions emitted by the runtime dependency.
- Human-readable formatting for the lower-level `container events` CLI in `apple/container`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter event
bash -n Tools/parity/check-compose-events.sh
git diff --check -- Sources/ComposeCore/ContainerEventsAdapter.swift Sources/ComposeCore/ComposeOrchestrator.swift Tests/ComposeCoreTests/ComposeOrchestratorTests.swift Tools/parity/check-compose-events.sh
```

Optional local Docker Compose V2 parity validation:

```sh
make docker-compose-events-parity
```

This optional parity target is not run by CI and should stay out of Apple-facing required checks.

## container-compose Checks

- [x] I updated `COMPATIBILITY.md` for runtime mapping changes.
- [x] I updated `STATUS.md` and `RESUME.md`.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I recorded source/reference issues and PRs, including why they were or were not used as a base.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.

## Remaining Risks

- Released upstream support still waits for accepted Apple runtime event-stream and event-filter APIs.
- The runtime replay cache is bounded and in-memory only; Docker daemon-style persistent event history is not part of this slice.
- The optional Docker-backed parity script extension has not yet been rerun after adding text replay validation.
