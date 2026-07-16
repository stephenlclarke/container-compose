# Handoff: unblock Compose network aliases with container-facing DNS

## Summary

- Keep Compose network aliases and `run --use-aliases` explicitly unavailable
  until they work for peer containers.
- Hand off the smallest runtime primitive needed to unblock the feature.
- Record why the existing alias-registration work is necessary but not
  sufficient.

## Type of Change

- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose supports service network aliases as network-scoped DNS names.
The local `apple/container` fork and upstream
[apple/container#1815](https://github.com/apple/container/pull/1815) provide
the required alias-registration data model, but that does not make an alias
resolvable by another service container.

The Compose mapping that formerly rendered `--network ...,alias=...` has been
intentionally disabled. `container-compose` now fails before side effects,
because live service containers point at their attachment gateway and the
runtime has no listener that can answer its attachment registry. Retaining the
rejection avoids claiming a feature that cannot work end to end.

The next implementation belongs in `apple/container`: expose a
container-facing DNS path that carries source-network context into the
existing attachment lookup. This is deliberately an Apple-shaped runtime
handoff, not a request to add Compose syntax to Apple code.

References:

- Compose service network `aliases`: <https://docs.docker.com/reference/compose-file/services/#aliases>
- Docker `network connect --alias`: <https://docs.docker.com/reference/cli/docker/network/connect/>
- Docker networking overview: <https://docs.docker.com/engine/network/>
- Runtime handoff files: `docs/upstream/apple-container/ISSUE-network-aliases.md` and `docs/upstream/apple-container/PR-network-aliases.md`
- [apple/container#1813](https://github.com/apple/container/pull/1813), which
  records that binding a listener to the vmnet gateway currently fails with
  `EADDRNOTAVAIL`
- Related apple/container networking discussions: [apple/container#1283](https://github.com/apple/container/issues/1283), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#500](https://github.com/apple/container/issues/500), [apple/container#1320](https://github.com/apple/container/issues/1320), [apple/container#282](https://github.com/apple/container/issues/282)

## Commit Tracking

- Historical Compose mapping commit: `0905db9` (`feat(network): map compose
  network aliases`); it is not enabled because peer resolution is absent.
- Alias-registration commit: `cf5e8d1` in `stephenlclarke/container`
  (`feat(network): add attachment aliases`).
- Current upstream equivalents: [apple/container#1813](https://github.com/apple/container/pull/1813) and [apple/container#1815](https://github.com/apple/container/pull/1815).
- No new fork commit is proposed until Apple identifies a supported vmnet DNS
  attachment point. A listener that happens to bind locally would be an
  unsupported and fragile workaround.

## Implementation Details

The proposed runtime change must:

1. Receive peer DNS traffic through a platform-supported vmnet mechanism
   without binding wildcard port 53 or racing `mDNSResponder`.
2. Carry the source interface/network through the DNS request to the network
   service, so the same alias can be resolved only in the originating
   network's registry.
3. Answer attachment hostnames and aliases using the existing allocator data,
   including cleanup after detach/remove.
4. Offer an integration test with real service containers, not only allocator
   or host-loopback DNS tests.

`container-compose` already validates aliases before it emits side effects and
has regression tests that assert its explicit container-facing-DNS error for
both `up` and `run --use-aliases`.

## Docker Compose Compatibility Notes

- Not supported today: Compose aliases and `run --use-aliases` remain partial
  because peer containers cannot resolve registered names.
- The alias data model is useful groundwork, but it currently uses a
  hostname-like uniqueness model. Docker-compatible shared aliases and
  multi-network behavior require the source-network-aware resolver proposed
  above.
- Service-name DNS for scaled replicas, DNSRR/VIP endpoint behavior, fixed
  IPs, and Docker network namespace modes remain separate networking gaps.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'ComposeOrchestratorTests/upRejectsNetworkAliasesUntilRuntimeExposesContainerFacingDNS|ComposeOrchestratorTests/runUseAliasesRejectsNetworkAliasesUntilRuntimeExposesContainerFacingDNS'
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
