# Pull request: add network attachment aliases

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker exposes network-scoped aliases as a container network attachment primitive. Compose service `networks.<name>.aliases` depends on that primitive, and Docker documents that aliases are resolved only on the network where the container is connected.

This change adds the generic runtime surface to `apple/container` without adding Compose-specific behavior. The local `container-compose` integration branch maps its single-network Compose alias subset onto this primitive; multi-network attach/connect and service DNS policy remain separate networking gaps.

Following JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), the durable upstream ask is the typed attachment alias primitive. Docker/Compose network syntax stays in `container-compose`; any local `--network ...,alias=...` parser is only a bridge for the current command-vector create path.

References:

- Docker `network connect --alias`: <https://docs.docker.com/reference/cli/docker/network/connect/>
- Docker networking overview, IP address and hostname: <https://docs.docker.com/engine/network/>
- Compose service network `aliases`: <https://docs.docker.com/reference/compose-file/services/#aliases>
- Related networking and DNS work: [apple/container#1283](https://github.com/apple/container/issues/1283), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#500](https://github.com/apple/container/issues/500), [apple/container#1320](https://github.com/apple/container/issues/1320), [apple/container#282](https://github.com/apple/container/issues/282)

## Commit Tracking

- Container code commit: `cf5e8d1` in `stephenlclarke/container` (`feat(network): add attachment aliases`).
- Lower runtime code commit: not required.
- Compose mapping code commit: `0905db9` in `stephenlclarke/container-compose` (`feat(network): map compose network aliases`), not part of this Apple PR.

## Implementation Details

- Added `aliases` to `AttachmentOptions` and `Attachment`, with backward-compatible decoding that treats missing aliases as `[]`.
- Added a network XPC `aliases` payload for allocation requests.
- Extended `AttachmentAllocator` to reserve hostname and alias names for the same address index and release them together.
- Updated container create validation so alias collisions fail before runtime resources are created.
- Passed aliases from create options through to runtime attachment allocation.
- The local fork also carried repeatable `alias=<name>` parsing on the `--network` attachment option and command-reference updates so the existing command-vector create path could validate the primitive; an upstream PR should drop or soften that bridge if maintainers prefer typed-only configuration.

## Compatibility Notes

- Existing persisted attachments that do not contain `aliases` continue to decode successfully.
- Existing `--network <name>`, `--network <name>,mac=...`, and `--network <name>,mtu=...` forms keep their current behavior.
- Alias names currently participate in the same uniqueness model as hostnames because the existing network lookup API is hostname-based and not source-network-scoped. Docker permits ambiguous alias sharing, but this smaller primitive is intentionally stricter until the DNS service can express network-scoped multi-answer behavior.
- This does not add multi-network connect/disconnect, fixed IPs, service-name DNS for replicas, DNSRR, legacy links, or Compose-specific alias selection.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ParserTest/testParseNetworkWithAliases|ParserTest/testParseNetworkDeduplicatesAliases|ParserTest/testParseNetworkEmptyAlias|AttachmentConfigurationTest|AttachmentAllocatorTest/testLookupAllocatedAlias|AttachmentAllocatorTest/testAliasConflictThrows|AttachmentAllocatorTest/testHostnameCannotReuseExistingAlias|AttachmentAllocatorTest/testDuplicateAliasMapsToSingleAllocation|AttachmentAllocatorTest/testDeallocateRemovesAliases'
```

Additional local checks:

```sh
make check
git diff --check
```
