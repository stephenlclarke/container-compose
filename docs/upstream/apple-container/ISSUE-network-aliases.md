# Feature request: container-facing DNS for network attachment aliases

## Feature or enhancement request details

Docker lets a container expose additional network-scoped DNS names when it joins a network:

```sh
docker network connect --alias db --alias mysql multi-host-network container2
```

Docker Compose uses the same concept through service network `aliases`:

```yaml
services:
  api:
    image: alpine
    networks:
      backend:
        aliases:
          - api.internal

networks:
  backend: {}
```

`apple/container` now has an alias-registration proposal in
[apple/container#1815](https://github.com/apple/container/pull/1815):
`AttachmentOptions.aliases` records extra names in the per-network attachment
registry. That is the right lower-level data model, but it is not enough for
Compose parity because service containers cannot query the registry.

[apple/container#1813](https://github.com/apple/container/pull/1813) confirms
the remaining platform constraint. It added forwarding and request-context
groundwork but deliberately does not start a container-facing listener:
wildcard UDP/53 conflicts with `mDNSResponder`, while binding the reported
vmnet gateway address fails with `EADDRNOTAVAIL` even when the vmnet DNS proxy
is disabled.

Compose owns `networks.<name>.aliases`, legacy `links`, selected network
restrictions, and Docker-compatible validation messaging. Apple owns a
supported path from a service container's DNS request to its source network's
attachment registry.

Relevant references:

- Docker `network connect --alias`: <https://docs.docker.com/reference/cli/docker/network/connect/>
- Docker networking overview, IP address and hostname: <https://docs.docker.com/engine/network/>
- Compose service network `aliases`: <https://docs.docker.com/reference/compose-file/services/#aliases>
- Related networking and DNS discussions: [apple/container#1283](https://github.com/apple/container/issues/1283), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#500](https://github.com/apple/container/issues/500), [apple/container#1320](https://github.com/apple/container/issues/1320), [apple/container#282](https://github.com/apple/container/issues/282)

## Proposed behavior

- Keep the existing `AttachmentOptions.aliases` groundwork.
- Expose a platform-supported resolver endpoint or DNS interception mechanism
  that receives requests from vmnet-backed service containers without binding
  wildcard port 53.
- Propagate source interface/network context to the network lookup path, so
  names are resolved in the correct attachment registry.
- Resolve an attachment hostname and its aliases over that container-facing
  path, then remove the answer after the attachment is released.
- Keep Compose syntax, service policy, DNSRR/VIP behavior, fixed IPs, and
  multi-network attach/connect out of this runtime change.

## Minimal example

Expected behavior:

- The created container receives its normal network attachment and aliases.
- A peer on the same `apple/container` network resolves `api.internal` to the
  same address as the attachment hostname through its configured DNS path.
- A peer attached only to a different network does not receive that answer.
- Existing callers that omit aliases preserve current behavior.

## Design boundary

Do not accept a host-loopback-only server or a listener that races
`mDNSResponder` as a solution. The vmnet helper needs a supported endpoint
provided by vmnet, packet interception, or another macOS networking facility.
The existing gateway bind experiments prove that changing Compose or adding
another `--network` parser cannot close this gap.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
