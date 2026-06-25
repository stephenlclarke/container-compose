# Pull request: support fork-backed `container compose top`

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

Docker Compose supports `docker compose top [SERVICES...]`. The plugin previously rejected the command because `apple/container` lacked process-listing support. The local fork stack now exposes a PID-only runtime primitive, so `container-compose` can implement the Compose selection and output layer without adding Compose-specific code to `apple/container`.

References:

- Docker Compose `top`: <https://docs.docker.com/reference/cli/docker/compose/top/>
- Docker `container top`: <https://docs.docker.com/reference/cli/docker/container/top/>
- Container handoff: `docs/upstream/process-list/ISSUE-container-process-identifiers.md` and `docs/upstream/process-list/PR-container-process-identifiers.md` in the `container` fork
- Lower runtime handoff: `docs/upstream/process-list/ISSUE-containerization-process-identifiers.md` and `docs/upstream/process-list/PR-containerization-process-identifiers.md` in the `containerization` fork

Existing upstream context:

- No open `apple/container` or `apple/containerization` issue or pull request was found for process listing or `top` support on 2026-06-22.

## Commit Tracking

- Compose code commit: `b44ba55` (`feat(top): support fork-backed process listing`)
- Container code commit: `14a3067` in `stephenlclarke/container` (`feat(runtime): expose container process identifiers`)
- Lower runtime code commits: `d69f7e5` and `aaa143b` in `stephenlclarke/containerization`

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
- The fork-backed output is intentionally PID-only because the current runtime exposes process identifiers, not full process metadata.
- Full Docker `top` columns remain blocked by an `apple/container` / `containerization` follow-up for richer process metadata.
- Branches pinned to released upstream `apple/container` must continue treating `top` as runtime-gated until equivalent process-listing APIs are accepted upstream.

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
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
