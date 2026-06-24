# Feature request: network attachment aliases

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

`apple/container` already allocates a hostname for each network attachment and resolves that hostname through the network service. It does not currently expose additional typed attachment aliases, so a Compose plugin cannot represent common service-discovery names without rewriting Compose files.

Direction note: after JLogan's 2026-06-23 guidance in [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328), this Apple-facing slice should stay focused on network attachment alias storage and lookup. Compose owns `networks.<name>.aliases`, legacy `links`, selected network restrictions, and Docker-compatible validation messaging.

Relevant references:

- Docker `network connect --alias`: <https://docs.docker.com/reference/cli/docker/network/connect/>
- Docker networking overview, IP address and hostname: <https://docs.docker.com/engine/network/>
- Compose service network `aliases`: <https://docs.docker.com/reference/compose-file/services/#aliases>
- Related networking and DNS discussions: [apple/container#1283](https://github.com/apple/container/issues/1283), [apple/container#457](https://github.com/apple/container/issues/457), [apple/container#456](https://github.com/apple/container/issues/456), [apple/container#500](https://github.com/apple/container/issues/500), [apple/container#1320](https://github.com/apple/container/issues/1320), [apple/container#282](https://github.com/apple/container/issues/282)

## Proposed behavior

- Add attachment `aliases` alongside the existing attachment hostname.
- Validate aliases with the same RFC1123 hostname rules used by explicit hostnames when Apple accepts direct user input for this field.
- Resolve aliases through the existing network lookup path.
- Preserve existing persisted network attachment decoding by defaulting missing aliases to an empty list.
- Keep multi-network attach/connect, DNSRR, fixed IPs, and Compose service policy out of this change.

## Minimal example

Expected behavior:

- The created container receives its normal network attachment.
- Peers on the same `apple/container` network can resolve `api.internal` to the same address as the attachment hostname.
- Existing callers that omit aliases preserve current behavior.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct
