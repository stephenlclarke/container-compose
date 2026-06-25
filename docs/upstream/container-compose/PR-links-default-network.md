# Pull Request

## Summary

- Add regression coverage for legacy `links` on the compose-go normalized implicit `default` network.
- Clarify the `links` error message so it applies to normalized default networks as well as user-declared networks.
- Update compatibility and plan docs to stop listing implicit default-network links as blocked.

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The existing `links` implementation projects aliases onto the linked target service when source and target share exactly one normalized Compose network. That means real Compose files that rely on the implicit `default` network are already representable after compose-go normalization.

The repository still had a manually constructed test and documentation that described implicit default-network links as unsupported. That was misleading because those fixtures skipped the normalized `default` network fields compose-go produces for real input.

References:

- Compose service `links`: <https://docs.docker.com/reference/compose-file/services/#links>
- Compose default network behavior: <https://docs.docker.com/reference/compose-file/networks/#the-default-network>
- Existing links handoff files: `docs/upstream/container-compose/ISSUE-links.md` and `docs/upstream/container-compose/PR-links.md`

## Commit Tracking

- Compose code commit: `87ef000` (`test(network): cover default links`)
- Compose feature dependency: `48367c7` (`feat(network): map compose links`)
- Container code dependency: `cf5e8d1` in `stephenlclarke/container` (`feat(network): add attachment aliases`)
- Lower runtime code commit: not required

## Implementation Details

- Added `upMapsLinksOnNormalizedDefaultNetwork` to cover the compose-go normalized `default` network shape.
- Updated the unsupported shared-network error text from "explicit Compose network" to "Compose network".
- Updated `PLAN.md` and `STATUS.md` to describe implicit default-network links as part of the supported single-network subset.

## Docker Compose Compatibility Notes

- Supported now on the fork-backed integration branch: `links` where linked services share exactly one normalized Compose network, including the implicit `default` network, currently through the command-vector bridge.
- Remaining gap: multi-network links, shared aliases, and `external_links` still need richer apple/container DNS and external-service lookup primitives.
- Remaining gap: released upstream still needs accepted network alias support before branches pinned to upstream can enable the alias projection.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/upMapsLinksOnNormalizedDefaultNetwork|ComposeOrchestratorTests/upRejectsLinksWithoutOneSharedNetwork'
```

Additional local checks:

```sh
make check
make coverage-check
markdownlint --disable MD013 MD041 -- STATUS.md PLAN.md STATUS.md docs/upstream/container-compose/ISSUE-links-default-network.md docs/upstream/container-compose/PR-links-default-network.md
git diff --check
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `PLAN.md` for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
