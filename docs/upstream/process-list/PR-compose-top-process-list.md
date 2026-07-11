# Pull request: support `container compose top`

<!-- markdownlint-disable MD013 -->

## Summary

- Replace the `compose top` unsupported placeholder with a direct API-backed implementation.
- Add a `ContainerTopAdapter` around `ContainerClient.processes(id:)`.
- Render a service-aware PID-only process table for selected service containers.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose supports `docker compose top [SERVICES...]`. The `stephenlclarke` stack exposes a PID-only runtime primitive, so `container-compose` can implement the Compose selection and output layer without adding Compose-specific code to `apple/container`.

References:

- Docker Compose `top`: <https://docs.docker.com/reference/cli/docker/compose/top/>
- Docker `container top`: <https://docs.docker.com/reference/cli/docker/container/top/>
- Container handoffs: [ISSUE-process-identifiers.md](../apple-container/ISSUE-process-identifiers.md) and [PR-process-identifiers.md](../apple-container/PR-process-identifiers.md)
- Lower-runtime handoffs: [ISSUE-process-identifiers.md](../apple-containerization/ISSUE-process-identifiers.md) and [PR-process-identifiers.md](../apple-containerization/PR-process-identifiers.md)

## Commit Tracking

- Compose code commit:
  `b44ba55496f747b37a915c1cf252dfd4a0c564c0` (`feat(top): support
  fork-backed process listing`).
- Container code commit:
  `02a04fb372a6629ba02a14d34c8f9ac5b5a755df` on
  `stephenlclarke/container:handoff/process-identifiers`
  (`feat(runtime): expose container process identifiers`).
- Lower runtime code commits:
  `d69f7e51c5ae9ecec6ad7fc4a6358b824cc515e7` and
  `aaa143b15f426912342cb4f29dc6a55065ba0651` in
  `stephenlclarke/containerization`.

## Implementation Details

- Added `ComposeTopOptions`.
- Added `ComposeTopTarget` and `ComposeTopRecord`.
- Added `ContainerTopAPIClienting`, `ContainerTopManaging`, `ContainerTopAPIClient`, and `ContainerClientTopManager`.
- Shared table rendering between stats and top adapters.
- Added `ComposeOrchestrator.top(project:options:)`.
- Updated the `Top` CLI command to load the project and call the orchestrator.
- Added tests for service-container selection, dry-run output, direct API forwarding, and table rendering.

## Docker Compose Compatibility Notes

- The CLI shape matches Docker Compose `top [SERVICES...]`.
- The `stephenlclarke` runtime output is intentionally PID-only because the current runtime exposes process identifiers, not full process metadata.
- Full Docker `top` columns remain blocked by an `apple/container` / `containerization` follow-up for richer process metadata.
- Stock `apple/container` builds must continue treating `top` as runtime-gated until equivalent process-listing APIs are accepted upstream.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter ComposeOrchestratorTests/top
swift test --filter ComposeOrchestratorTests/dependencyGroupsPreserveIndividuallyConfiguredCollaborators
swift test --filter ComposeOrchestratorTests/statsManagerRendersStaticTableFromDirectAPIStats
```

Additional local checks:

```sh
swift build --product compose
make format
git diff --check
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
