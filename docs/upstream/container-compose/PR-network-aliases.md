# Pull Request

## Summary

- Map Compose network aliases to the plugin-owned network-alias projection for the single-network local subset.
- Validate alias names and alias network ownership before side effects.
- Document the remaining multi-network/DNS parity gaps.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose supports service network aliases as network-scoped DNS names. The plugin previously rejected the whole surface because released upstream `apple/container` did not expose attachment aliases.

The local container fork now adds a generic network attachment alias primitive with `AttachmentOptions.aliases`. This plugin change keeps Compose policy in `container-compose`: it only maps aliases when the service has exactly one attached network, validates the aliases with Docker-compatible RFC1123 hostname rules, and leaves multi-network alias parity blocked until the runtime exposes richer networking behavior. The current live execution path still renders repeatable `container run/create --network <name>,alias=<value>` through the command-vector bridge while typed service creation is being wired.

References:

- Compose service network `aliases`: <https://docs.docker.com/reference/compose-file/services/#aliases>
- Docker `network connect --alias`: <https://docs.docker.com/reference/cli/docker/network/connect/>
- Docker networking overview: <https://docs.docker.com/engine/network/>
- Runtime handoff files: `docs/upstream/apple-container/ISSUE-network-aliases.md` and `docs/upstream/apple-container/PR-network-aliases.md`
- Related apple/container networking discussions: [apple/container#1283](https://github.com/apple/container/issues/1283), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#500](https://github.com/apple/container/issues/500), [apple/container#1320](https://github.com/apple/container/issues/1320), [apple/container#282](https://github.com/apple/container/issues/282)

## Commit Tracking

- Compose code commit: `0905db9` (`feat(network): map compose network aliases`)
- Container code commit: `cf5e8d1` in `stephenlclarke/container` (`feat(network): add attachment aliases`)
- Lower runtime code commit: not required

## Implementation Details

- Replaced the blanket network-alias rejection with `validateNetworkAliasSupport(service:networks:)`.
- Added shared RFC1123 hostname canonicalization for hostname-like Compose fields.
- Added `networkAliasValues(service:network:)` to validate, canonicalize, and de-duplicate aliases before rendering.
- Built alias projections for the single network attachment.
- Appended aliases to the single `--network` attachment argument before MAC and MTU options in the current command-vector bridge.
- Added positive `up` and one-off `run` tests for alias rendering.
- Added negative tests for invalid aliases and aliases declared on unattached networks.
- Updated `STATUS.md` and relevant project docs.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed integration branch: aliases on exactly one service network, currently through the command-vector bridge.
- Supported now: alias rendering alongside single-network MAC and MTU options.
- Remaining gap: Docker permits the same network-wide alias to be shared by multiple containers, with unspecified resolution. The local runtime currently keeps alias names unique because the existing lookup path is hostname-like and not source-network-scoped.
- Remaining gap: aliases on services with multiple networks need `apple/container` multi-network attach/connect and source-network-aware DNS behavior.
- Remaining gap: service-name DNS for scaled replicas, DNSRR/VIP endpoint behavior, fixed IPs, and Docker network namespace modes remain separate networking gaps.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/upMapsNetworkAliasesToSingleNetworkAttachment|ComposeOrchestratorTests/upRejectsInvalidNetworkAliasesBeforeCreatingResources|ComposeOrchestratorTests/upRejectsAliasesOnUnattachedNetworksBeforeCreatingResources|ComposeOrchestratorTests/runMapsNetworkAliasesToSingleNetworkAttachment'
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
