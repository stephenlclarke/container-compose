# Handoff PR: add container-facing DNS for network attachment aliases

## Type of Change

- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker exposes network-scoped aliases as a container network attachment
primitive. [apple/container#1815](https://github.com/apple/container/pull/1815)
already supplies that storage and allocator primitive. The remaining failure
is that service containers have no supported DNS route to the allocator.

[apple/container#1813](https://github.com/apple/container/pull/1813) tested
the obvious listener designs and deliberately leaves listener startup out:
wildcard UDP/53 races with `mDNSResponder`, and a listener bound to the vmnet
gateway fails with `EADDRNOTAVAIL`, including after disabling the vmnet DNS
proxy. This handoff asks for the smallest Apple-owned mechanism that can
actually receive service DNS traffic and retain source-network context.

Docker/Compose network syntax stays in `container-compose`. No Compose-facing
parser or policy belongs in this Apple change.

References:

- Docker `network connect --alias`: <https://docs.docker.com/reference/cli/docker/network/connect/>
- Docker networking overview, IP address and hostname: <https://docs.docker.com/engine/network/>
- Compose service network `aliases`: <https://docs.docker.com/reference/compose-file/services/#aliases>
- Related networking and DNS work: [apple/container#1283](https://github.com/apple/container/issues/1283), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#500](https://github.com/apple/container/issues/500), [apple/container#1320](https://github.com/apple/container/issues/1320), [apple/container#282](https://github.com/apple/container/issues/282)

## Commit Tracking

- Alias-registration groundwork: `cf5e8d1` in `stephenlclarke/container`
  (`feat(network): add attachment aliases`) and upstream
  [apple/container#1815](https://github.com/apple/container/pull/1815).
- DNS groundwork: [apple/container#1813](https://github.com/apple/container/pull/1813).
- No new fork commit is proposed until maintainers identify the supported
  vmnet-facing endpoint. The failed gateway-bind experiment is documented
  upstream and should not be replaced with a local-only workaround.

## Implementation Details

The Apple implementation should be limited to the runtime plumbing:

1. Obtain a supported vmnet or macOS networking endpoint for DNS traffic from
   guest service containers; do not bind wildcard port 53.
2. Pass the ingress interface/network identity into the DNS handler and
   attachment lookup.
3. Resolve the existing hostname and alias entries from that network only,
   preserving allocator cleanup semantics.
4. Add an integration test that creates two real service containers and
   resolves both the primary hostname and alias from the peer's configured DNS
   path.

The resolver should support both UDP and TCP if the selected platform endpoint
requires it. The exact listener/packet-interception API is intentionally left
to Apple maintainers because the known direct socket binds are not viable.

## Compatibility Notes

- Existing persisted attachments that omit `aliases` continue to decode
  successfully.
- Existing attachment CLI forms retain their current behavior.
- Alias names currently participate in a hostname-like uniqueness model. The
  source-network-aware resolver is the prerequisite for Docker-compatible
  shared aliases and multi-network behavior.
- This does not add multi-network connect/disconnect, fixed IPs, service-name
  DNS for replicas, DNSRR, legacy links, or Compose-specific alias selection.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter 'AttachmentAllocatorTest|ForwardingResolverTest|CompositeResolverTest'
```

The change is incomplete until a vmnet-backed integration test demonstrates
peer resolution. Allocator and host-loopback tests alone are not acceptance
evidence.

Additional local checks:

```sh
make check
git diff --check
```
