# Pull request: add explicit container hostname configuration

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker exposes `docker container run --hostname` for setting the hostname visible inside the container UTS namespace, and Docker Compose exposes the same concept with the service `hostname` key. `apple/container` already derives a default hostname from the first network attachment, but it does not currently let typed API callers set one explicitly.

This change adds that missing runtime primitive without adding Compose-specific behavior to `apple/container`. It is intentionally limited to `hostname` because `containerization` currently exposes `LinuxContainer.Configuration.hostname`; `domainname` should be handled as a separate runtime API discussion if maintainers want OCI `domainname` bridged too. Following JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), any Docker-shaped CLI bridge in the local fork should be treated as validation plumbing rather than the durable upstream ask.

References:

- Docker CLI `container run --hostname`: <https://docs.docker.com/reference/cli/docker/container/run/>
- Compose service `hostname`: <https://docs.docker.com/reference/compose-file/services/#hostname>
- Related networking and identity work: [apple/container#1563](https://github.com/apple/container/pull/1563), [apple/container#1340](https://github.com/apple/container/pull/1340), [apple/container#673](https://github.com/apple/container/issues/673), [apple/container#282](https://github.com/apple/container/issues/282)

## Implementation Details

- Added `ContainerConfiguration.hostname`.
- Added RFC1123 label validation for direct caller input.
- Set `ContainerConfiguration.hostname` during client-side configuration assembly.
- Made `RuntimeService` prefer the explicit hostname, then fall back to the current network-derived hostname behavior.
- The local fork also carried `-h, --hostname <hostname>` parser and command-reference changes so the existing create path could validate the primitive; an upstream PR should drop or soften that bridge if maintainers prefer typed-only configuration.

## Commit Tracking

- Container code commit: `819eeda` in `stephenlclarke/container` (`feat(api): add container hostname option`).
- Lower runtime code commit: not required.
- Compose mapping code commit: `78398e2` in `stephenlclarke/container-compose` (`feat(network): map compose hostnames`), not part of this Apple PR.

## Compatibility Notes

- This preserves the current default hostname behavior for callers that do not set an explicit hostname.
- This does not add domain names, DNS search domains, network aliases, Compose service aliases, or legacy link semantics.
- The hostname is a container runtime primitive; Compose translation remains in `container-compose`.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused tests:

```sh
swift test --filter 'ParserTest/testHostnameParserAcceptsRFC1123Name|ParserTest/testHostnameParserRejectsEmptyValue|ParserTest/testHostnameParserRejectsInvalidLabel|ParserTest/testManagementFlagsAcceptsHostname|ParserTest/testManagementFlagsAcceptsShortHostname|ContainerConfigurationHostnameTests|RuntimeServiceHostsTests'
```

Additional checks:

```sh
make check
git diff --check
```
