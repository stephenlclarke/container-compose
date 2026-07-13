# Pull Request

## Summary

- Map legacy Compose `links` to implicit service dependencies plus target
  service network aliases for the safe single-network local subset.
- Validate link syntax, target services, alias names, shared network
  ownership, and projected link-alias conflicts before side effects.
- Document current Docker Compose parity gaps around multi-network links,
  source-scoped DNS, and shared aliases.

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
typed attachment aliases. This plugin change maps only the part of `links` that
can be represented cleanly by that primitive. The current live execution path
still renders `container run/create --network <name>,alias=<value>` through the
command-vector bridge while typed service creation is being wired.
Compose-specific legacy-link parsing stays in `container-compose`; no
Compose-specific policy is added to `apple/container`.

References:

- Compose service `links`: <https://docs.docker.com/reference/compose-file/services/#links>
- Compose service network `aliases`: <https://docs.docker.com/reference/compose-file/services/#aliases>
- Docker `network connect --alias`: <https://docs.docker.com/reference/cli/docker/network/connect/>
- Runtime alias handoff files: `docs/upstream/apple-container/ISSUE-network-aliases.md`
  and `docs/upstream/apple-container/PR-network-aliases.md`
- Related `apple/container` networking issues: [apple/container#1283](https://github.com/apple/container/issues/1283), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#500](https://github.com/apple/container/issues/500), [apple/container#1320](https://github.com/apple/container/issues/1320)

## Commit Tracking

- Compose code commit: `48367c7` (`feat(network): map compose links`)
- Container code dependency: `cf5e8d1` in `stephenlclarke/container` (`feat(network): add attachment aliases`)
- Lower runtime code commit: not required

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
- Keep `external_links` policy separate from service links; the current
  single-network external-link subset uses direct runtime inspection and
  generated host entries.
- Updated `STATUS.md` and relevant project docs.

## Docker Compose Compatibility Notes

- Supported with the current fork-backed runtime: `links` for services that
  share exactly one normalized Compose network, including the implicit
  `default` network, currently through the command-vector bridge.
- Supported: `SERVICE:ALIAS` link aliases.
- Supported: `SERVICE` entries mapped to the target service name as an
  alias.
- Supported: implicit dependency ordering from links.
- Remaining gap: Docker-compatible shared aliases and source-scoped DNS.
- Remaining gap: multi-network link behavior.
- Separate supported subset: `external_links` uses direct runtime inspection
  and generated host entries when the source and external container share one
  runtime network.

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

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
