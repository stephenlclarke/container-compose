# Pull Request

## Summary

- Map legacy Compose `links` to implicit service dependencies plus target
  service network aliases for the safe single-network local subset.
- Validate link syntax, target services, alias names, explicit shared network
  ownership, and projected link-alias conflicts before side effects.
- Document remaining Docker Compose parity gaps around default-network service
  discovery, source-scoped DNS, shared aliases, and `external_links`.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose still accepts the legacy `links` field. Links are no longer
needed for ordinary service-to-service communication, but they remain part of
the Compose file surface and they carry two behaviors: implicit dependency
ordering and optional alias names for the linked service.

The local container fork now exposes a single-network alias primitive through
`container run/create --network <name>,alias=<value>`. This plugin change maps
only the part of `links` that can be represented cleanly by that primitive.
Compose-specific legacy-link parsing stays in `container-compose`; no
Compose-specific policy is added to `apple/container`.

References:

- Compose service `links`: <https://docs.docker.com/reference/compose-file/services/#links>
- Compose service network `aliases`: <https://docs.docker.com/reference/compose-file/services/#aliases>
- Docker `network connect --alias`: <https://docs.docker.com/reference/cli/docker/network/connect/>
- Runtime alias handoff files in the container fork: `ISSUE-network-aliases.md`
  and `PR-network-aliases.md`
- Related `apple/container` networking issues: [apple/container#1283](https://github.com/apple/container/issues/1283), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#500](https://github.com/apple/container/issues/500), [apple/container#1320](https://github.com/apple/container/issues/1320)

## Implementation Details

- Added `ComposeLinkReference` plus parser helpers for `SERVICE` and
  `SERVICE:ALIAS` link entries.
- Included link targets in `serviceDependencies(_:)` so `up`, `create`, and
  one-off `run` start linked services before dependents unless `--no-deps`
  removes dependency startup.
- Added `projectByApplyingLinks(project:activeServiceNames:)` to build a
  runtime working project with active link aliases projected onto linked target
  services before validation, config hashing, resource creation, and container
  creation.
- Added a projected link-alias validation guard because the current fork-backed
  `apple/container` alias lookup is hostname-like and cannot model Docker's
  ambiguous shared-alias behavior yet.
- Kept `external_links` unsupported because it needs external service lookup and
  alias handoff primitives that are not available.
- Updated `COMPATIBILITY.md`, `PLAN.md`, and `STATUS.md`.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed integration branch: `links` for services
  that share exactly one explicit Compose network.
- Supported now: `SERVICE:ALIAS` link aliases.
- Supported now: `SERVICE` entries mapped to the target service name as an
  alias.
- Supported now: implicit dependency ordering from links.
- Remaining gap: implicit default-network service discovery and aliases when no
  explicit Compose network appears in the normalized model.
- Remaining gap: Docker-compatible shared aliases and source-scoped DNS.
- Remaining gap: `external_links` and multi-network link behavior.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/upMapsLinksToTargetNetworkAliases|ComposeOrchestratorTests/upMapsLinkWithoutAliasToTargetServiceName|ComposeOrchestratorTests/upRejectsInvalidLinkAliasesBeforeCreatingResources|ComposeOrchestratorTests/upRejectsLinksWithoutOneExplicitSharedNetwork|ComposeOrchestratorTests/upRejectsSharedLinkAliasesBeforeCreatingResources|ComposeOrchestratorTests/runMapsLinksToDependencyNetworkAliases'
```

Additional local checks:

```sh
make check
make coverage-check
git diff --check
```

## container-compose Checks

- [x] I updated `COMPATIBILITY.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
