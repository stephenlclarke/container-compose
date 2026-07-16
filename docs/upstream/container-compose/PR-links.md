# Pull Request

## Summary

- Map legacy Compose `links` to implicit service dependencies plus generated
  source-container static host entries for the safe single-network local
  subset.
- Validate link syntax, target services, alias names, and shared network
  ownership before resources are created.
- Document current Docker Compose parity gaps around dynamic aliases,
  multi-network links, and source-scoped DNS.

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

The local container fork exposes container inspection and explicit host-entry
injection. This plugin maps only the part of `links` that can be represented
cleanly by those primitives: after the target is created, the source receives
`--add-host <alias>:<target-ip>`. Compose-specific legacy-link parsing stays
in `container-compose`; no Compose-specific policy is added to
`apple/container`.

References:

- Compose service `links`: <https://docs.docker.com/reference/compose-file/services/#links>
- Compose service network `aliases`: <https://docs.docker.com/reference/compose-file/services/#aliases>
- Docker `network connect --alias`: <https://docs.docker.com/reference/cli/docker/network/connect/>
- Runtime alias handoff files: `docs/upstream/apple-container/ISSUE-network-aliases.md`
  and `docs/upstream/apple-container/PR-network-aliases.md`
- Related `apple/container` networking issues: [apple/container#1283](https://github.com/apple/container/issues/1283), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#500](https://github.com/apple/container/issues/500), [apple/container#1320](https://github.com/apple/container/issues/1320)

## Commit Tracking

- Compose code commit: `feat(links): resolve legacy links through host entries`
  on this pull request
- Container code dependency: existing matched `stephenlclarke/container`
  inspection and host-entry APIs
- Lower runtime code commit: not required

## Implementation Details

- Added `ComposeLinkReference` plus parser helpers for `SERVICE` and
  `SERVICE:ALIAS` link entries.
- Included link targets in `serviceDependencies(_:)` so `up`, `create`, and
  one-off `run` start linked services before dependents unless `--no-deps`
  removes dependency startup.
- Added `projectByValidatingLinks(project:activeServiceNames:)` to validate
  link topology before resources are created.
- Added `serviceByResolvingLinkHosts(project:service:scaleOverrides:)` so
  `up`, `create`, and one-off `run` inspect created link targets and add static
  `ALIAS=IP` entries to only the dependent source service before config
  hashing and container creation.
- Reject a source `extra_hosts` mapping that conflicts with a link alias before
  resource creation instead of relying on unspecified host-file ordering.
- Reject one link alias that refers to multiple services before resource
  creation instead of relying on unspecified host-file ordering.
- Keep `external_links` policy separate from service links; the current
  single-network external-link subset uses direct runtime inspection and
  generated host entries.
- Updated `STATUS.md` and relevant project docs.

## Docker Compose Compatibility Notes

- Supported with the current fork-backed runtime: `links` for services that
  share exactly one normalized Compose network, including the implicit
  `default` network, through generated `--add-host` source entries.
- Supported: `SERVICE:ALIAS` static link host entries.
- Supported: `SERVICE` entries mapped to the target service name as a static
  host entry.
- Supported: implicit dependency ordering from links.
- Remaining gap: dynamic source-scoped DNS aliases and address update events.
- Remaining gap: links with zero or multiple shared networks.
- Separate supported subset: `external_links` uses direct runtime inspection
  and generated host entries when the source and external container share one
  runtime network.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter LegacyLinks
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
