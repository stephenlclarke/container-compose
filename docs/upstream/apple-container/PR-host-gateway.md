# Pull request: resolve host-gateway host entries

## Type of Change

- [ ] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker supports a special `host-gateway` value in `--add-host` entries. Docker Compose commonly uses this as `extra_hosts: ["host.docker.internal:host-gateway"]` so containers can reach services running on the host machine without hard-coding the bridge gateway address.

The local fork already has static host-entry support, and runtime network attachments already include an IPv4 gateway. This change resolves a typed host-gateway marker at the runtime boundary where that gateway is known, without adding Compose-specific behavior to `apple/container`.

Following JLogan's guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), Docker/Compose string handling stays in `container-compose`. The useful Apple primitive is the runtime-resolved host-entry marker and pre-start `/etc/hosts` generation.

References:

- Docker `container run --add-host` and `host-gateway`: <https://docs.docker.com/reference/cli/docker/container/run/#add-entries-to-container-hosts-file---add-host>
- Compose service `extra_hosts`: <https://docs.docker.com/reference/compose-file/services/#extra_hosts>
- Related host-entry PRs: [apple/container#1563](https://github.com/apple/container/pull/1563), [apple/container#1340](https://github.com/apple/container/pull/1340)

## Implementation Details

- Added `ContainerConfiguration.HostEntry.hostGatewayAddress` and `requiresHostGateway`.
- Resolved host-gateway entries to the first network interface IPv4 gateway when generating runtime `/etc/hosts`.
- Added a clear invalid-argument error when host-gateway is requested without an available gateway.
- The local fork also allowed `Parser.hostEntries(_:)` to accept `host-gateway` as the address side of `--add-host` so the existing command-vector create path could validate the primitive; an upstream PR should drop or soften that bridge if maintainers prefer typed-only configuration.

## Commit Tracking

- Container code commit: `ebbd611` in `stephenlclarke/container` (`feat(network): resolve host gateway entries`).
- Container dependency commit: `bf1d6b4` (`feat(api): add explicit host entries`).
- Lower runtime code commit: not required.
- Compose mapping code commit: `04d144e` in `stephenlclarke/container-compose` (`feat(network): map compose host gateway`), not part of this Apple PR.

## Compatibility Notes

- Static IPv4 and IPv6 `--add-host` behavior is unchanged.
- This slice does not add daemon-level configurable host-gateway override addresses.
- This slice does not add DNS aliases, multi-network alias selection, or Compose link semantics.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused tests:

```sh
swift test --filter 'ParserTest/testHostEntriesParserAcceptsHostGateway|ContainerConfigurationHostEntryTests/hostGatewayEntryIdentifiesRuntimeResolution|RuntimeServiceHostsTests/resolvedHostsResolvesHostGatewayToPrimaryGateway|RuntimeServiceHostsTests/resolvedHostsRejectsHostGatewayWithoutGatewayAddress'
```

Additional checks:

```sh
make check
make test
git diff --check
```
