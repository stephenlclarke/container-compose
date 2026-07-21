# Compose compatibility: IPv6 IPAM gateway

## Compose surface

- `networks.NETWORK_NAME.ipam.config[].gateway` for an IPv6 subnet

## Docker Compose v2 behavior

Docker Compose retains an IPv6 pool's configured `gateway` in `config` output and forwards it to Docker Engine when IPv6 is enabled. The gateway must be a usable address in the corresponding subnet. When `enable_ipv6: false`, Docker Compose still renders the declared pool and gateway, while Docker Engine ignores both during network creation.

References:

- [Compose networks reference](https://docs.docker.com/reference/compose-file/networks/#ipam)
- [Docker Engine network create reference](https://docs.docker.com/reference/cli/docker/network/create/)

## Current container-compose behavior

container-compose preserves one IPv6 pool gateway through Compose normalization, `config`/`convert`, the runtime-neutral resource contract, and dry-run output. It validates that an enabled gateway has an IPv6 subnet, is unzoned and specified, belongs to that subnet, and is not reused as a static service address. The effective macOS request renders `--subnet-v6` and `--gateway-v6` together.

For `enable_ipv6: false`, the Compose model retains both values for Docker-compatible configuration output while the effective request omits them. That prevents the macOS runtime from receiving mutually exclusive IPv6 settings.

## Ownership and handoff

container-compose owns Docker Compose parsing, validation, model retention, policy for disabled IPv6, and Docker-shaped parity output.

The Compose implementation is the signed commit [`134b2581`](https://github.com/stephenlclarke/container-compose/commit/134b25819f366f5fc44dc6b785406b481363a10e). It pins the generic runtime control to [`c194d29`](https://github.com/stephenlclarke/container/commit/c194d298449ffbd0a8a30f3307e75900a0b11970) and the supporting Containerization API to [`fe272b2`](https://github.com/stephenlclarke/containerization/commit/fe272b22c133bd82e319d3c91863fe11abe708a0). The generic API contains no Compose parser, labels, project naming, or Docker-output policy.

Windows-specific networking is out of scope.

## Validation

- Go normalizer tests cover IPv6 gateway normalization and unsupported IPv6 range handling.
- Swift unit tests cover normalization, validation, dry-run rendering, request forwarding, and suppression when IPv6 is disabled.
- A macOS Compose runtime smoke test creates an IPv6 network with `fd00:10::53` as its gateway and verifies network configuration and status.
- The focused generic CLI integration verifies the guest receives that address as its IPv6 default route.
- `Tools/parity/check-compose-network-ipv6.sh` compares automatic IPv6, explicit gateway, and disabled IPv6 configuration with Docker Compose v5.3.1.
- The complete local coverage gate passed: 1,112 Swift tests, 91.39% Swift coverage, and 90.06% Go coverage.

## Remaining macOS gaps

IPv6 allocation ranges, IPv6 auxiliary addresses, multiple IPv6 pools, disabled IPv4, embedded DNS, and service discovery remain unsupported. This slice does not change Windows or Linux-host behavior.
