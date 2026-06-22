<!-- markdownlint-disable MD013 -->

# feat(events): map Compose events to runtime event stream

## Summary

- Implement `container compose events --json [SERVICE...]` through `ContainerClient.events()`.
- Filter runtime events to Compose project/service containers, skip one-off containers, and strip Compose-private labels from rendered attributes.
- Add focused unit coverage and an optional local-only Docker Compose V2 parity check.

## Type Of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation And Context

Docker Compose exposes `docker compose events --json [SERVICE...]` for project-scoped container lifecycle events. `container-compose` already normalized the command name but previously rejected it because released upstream `apple/container` did not expose an event stream.

This PR is the Compose-side mapping slice. It stacks on the separate Apple-shaped runtime primitive documented in `PR-container-events-stream.md`, which references [apple/container#484](https://github.com/apple/container/issues/484) and adds `ContainerEvent` plus `ContainerClient.events()` without Compose policy.

Existing source and dependency decisions:

- **Base issue:** [apple/container#484](https://github.com/apple/container/issues/484) is the upstream source request for a generic event stream.
- **Runtime dependency:** `docs/upstream/events/PR-container-events-stream.md` is the required `apple/container` PR-shaped dependency. Its constructible code commits are `b71e4bb323e3` and `0da7890b2632` in `stephenlclarke/container`.
- **No lower-runtime dependency:** no `apple/containerization` change is required for this first Compose mapping because the runtime event source is already exposed by `ContainerClient.events()`.
- **Not based on Docker Compose code:** Docker Compose is Go code over Docker engine events and Docker label keys. This PR uses Docker Compose as behavioral guidance, not as a source-code base.
- **Docker behavioral reference:** Docker Compose source at `docker/compose@9b55a6e9c1016fd3c31859b7e09260378d45a783` filters to container events, skips one-off containers, applies selected-service filtering, strips internal labels, and renders `time`, `type`, `service`, `id`, `action`, and `attributes`.
- **Scope guard:** [docker/compose#13700](https://github.com/docker/compose/issues/13700) confirms current Compose event output is container-event scoped. Network, volume, image, and health-status events stay future work even though the runtime payload can grow to support them later.

## Commit Tracking

- Compose code commit to squash:
  - `113be38063ea feat(events): map compose events`
- Container code commits to stack on:
  - `b71e4bb323e3 feat(events): stream container lifecycle events`
  - `0da7890b2632 fix(events): avoid blocking slow event subscribers`
- Container handoff-doc commits:
  - `48b763c docs(events): record container event stream handoff`
  - `24dcfbc docs(events): update event stream commit tracking`
- Lower runtime code commit: not required

Use the Compose code commit as one future `container-compose` PR. Use the container code commits as the separate future `apple/container` PR. Do not squash the Compose mapping into the Apple runtime PR.

## Implementation Details

- Added `ContainerEventsAdapter.swift` with:
  - `ComposeEventRecord`
  - `ContainerEventsAPIClienting`
  - `ContainerEventsManaging`
  - `ContainerEventsAPIClient`
  - `ContainerClientEventsManager`
- Added `ComposeEventsOptions`.
- Added `eventsManager` dependency injection through `ComposeOrchestratorRuntimeDependencies`.
- Added `ComposeOrchestrator.events(project:options:)`.
- Replaced the `Events` placeholder in `ComposePlugin.swift` with an async project-backed command.
- `--json` is required for this first slice; non-JSON formatting remains a later plugin feature.
- `--since` and `--until` are rejected with explicit runtime-gap messages because the local `ContainerClient.events()` primitive is a live stream without replay or timestamp-filter semantics.
- Dry-run renders the generic runtime command `container events`.
- Added focused tests for service selection, dry-run behavior, option gating, and event-stream JSON filtering/rendering.
- Added `Tools/parity/check-compose-events.sh` and `make docker-compose-events-parity` as an opt-in Docker Compose V2 comparison that is intentionally not part of CI.

## Docker Compose Compatibility Notes

Supported on the fork-backed integration stack:

- `container compose events --json`
- `container compose events --json SERVICE...`
- Project label filtering
- Selected-service filtering
- One-off container suppression
- Compose-private attribute stripping for both `com.apple.container.compose.*` and `com.docker.compose.*`
- JSON Lines output with fields `time`, `type`, `service`, `id`, `action`, and `attributes`

Explicitly not supported in this slice:

- Non-JSON event formatting
- Event replay or historical filtering through `--since`
- Automatic stop at `--until`
- Network, volume, image, health, and restart-policy metadata events beyond the container lifecycle transitions emitted by the runtime dependency

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
/usr/bin/swift test --filter eventManagerFiltersRuntimeStreamToComposeJSONServiceEvents
/usr/bin/swift test --filter 'events|dependency groups'
bash -n Tools/parity/check-compose-events.sh
/usr/bin/swift test --filter 'eventManagerFiltersRuntimeStreamToComposeJSONServiceEvents|dependencyGroupsPreserveIndividuallyConfiguredCollaborators'
/usr/bin/swift build --product compose
make cli-smoke-built
git diff --check
git ls-files --modified --others --exclude-standard '*.md' | sort | xargs markdownlint
./Tools/parity/check-compose-events.sh
```

The non-strict Docker parity run skipped cleanly in this shell because Docker Compose V2 was not available:

```text
warning: Docker Compose V2 is not available; skipping Docker Compose events parity check
```

Optional local Docker Compose V2 parity validation:

```sh
make docker-compose-events-parity
```

This optional parity target is not run by CI and should stay out of Apple-facing required checks.

## container-compose Checks

- [x] I updated `COMPATIBILITY.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for the active slab.
- [x] I updated `STATUS.md` and `RESUME.md`.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I recorded source/reference issues and PRs, including why they were or were not used as a base.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.

## Remaining Risks

- Released upstream `apple/container` still needs an accepted event-stream API before this support can move from fork-backed to released-upstream compatible.
- Runtime events are live-only. Users asking for `--since` / `--until` should receive clear errors until a replay/filter contract exists.
- Event timestamps come from the API-service runtime primitive, not Docker engine event time. This is acceptable for the local stack but should be called out if Apple maintainers choose a lower-level event source later.
