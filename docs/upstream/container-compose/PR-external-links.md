# Pull Request

## Summary

- Map legacy Compose `external_links` to generated host entries for the safe single-shared-runtime-network local subset.
- Project apple/container network attachments through the direct discovery adapter so Compose can resolve external container IPv4 addresses without shelling out.
- Document remaining Docker Compose parity gaps around source-scoped DNS, shared aliases, and richer external-service lookup.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose still accepts the legacy `external_links` field for linking a service container to a container or service managed outside the current Compose application. Docker Compose v2 keeps this as part of its `getLinks` path and passes `external:alias` entries to the Docker engine link surface.

apple/container does not currently expose a Docker-compatible `HostConfig.Links` equivalent. The local fork does expose two narrower primitives that can model a useful local subset: direct container snapshot inspection and explicit host-entry injection. The current live execution path still renders generated host entries through `container run/create --add-host` while typed service creation is being wired.

This change keeps Compose-specific legacy-link policy in `container-compose`. It resolves `external_links` only when the external container is visible through the direct API and exactly one source runtime network can be matched. Anything more ambiguous still fails clearly instead of guessing.

References:

- Compose service `external_links`: <https://docs.docker.com/reference/compose-file/services/#external_links>
- Docker Compose v2 `getLinks` implementation: <https://github.com/docker/compose/blob/main/pkg/compose/convergence.go>
- compose-go `ExternalLinks` model: <https://github.com/compose-spec/compose-go/blob/main/types/types.go>
- compose-go external-links loader coverage: <https://github.com/compose-spec/compose-go/blob/main/loader/tests/external_links_test.go>
- Related apple/container DNS/interface issues: [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#310](https://github.com/apple/container/issues/310)
- Related apple/container host-entry PR direction: [apple/container#1340](https://github.com/apple/container/pull/1340)

## Commit Tracking

- Compose code commit: `81c164d` (`feat(network): map compose external links`)
- Container code dependency: `bf1d6b4` in `stephenlclarke/container` (`feat(api): add explicit host entries`)
- Lower runtime code commit: not required

## Implementation Details

- Added `ComposeContainerNetworkAttachment` and projected `ContainerSnapshot.networks` through `ContainerClientDiscoveryManager`.
- Added `ComposeExternalLinkReference` parsing for `CONTAINER` and `CONTAINER:ALIAS`.
- Added `projectByResolvingExternalLinks(project:services:)` so `up`, `create`, and one-off `run` work with a transient project that includes generated host entries before resource creation, config hashing, and container creation.
- Resolved each external link through `discoveryManager.getContainer(id:)`.
- Required the source service to have exactly one Compose network.
- Required the referenced external container to have exactly one attachment on the source service's runtime network.
- Generated `ALIAS=IP` transient host entries, letting the existing `extra_hosts` projection currently produce `--add-host ALIAS:IP` through the command-vector bridge.
- Kept multi-network, missing-container, and no-shared-network cases as clear pre-side-effect errors.
- Updated `PLAN.md` and `STATUS.md`.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed integration branch: `external_links` where the source service has exactly one Compose network and the external apple/container container has exactly one attachment on the matching runtime network.
- Supported now: `CONTAINER:ALIAS` external link aliases.
- Supported now: `CONTAINER` entries mapped to the external container name as the alias.
- Supported now: generated host entries participate in config-hash recreate behavior.
- Remaining gap: Docker-compatible source-scoped link lookup.
- Remaining gap: multi-network external links.
- Remaining gap: shared aliases and richer external-service discovery.
- Remaining upstream gap: released apple/container still needs accepted host-entry and network-inspection surfaces before this can be enabled without the fork.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/runMapsExternalLinksToGeneratedHostEntries|ComposeOrchestratorTests/runRejectsMissingExternalLinksBeforeCreatingResources|ComposeOrchestratorTests/upMapsExternalLinksToGeneratedHostEntries|ComposeOrchestratorTests/upRejectsExternalLinksWithoutSharedRuntimeNetwork|ComposeOrchestratorTests/discoveryManagerMapsContainerSnapshotsToComposeSummaries'
```

Additional local checks:

```sh
make check
make coverage-check
git diff --check
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
