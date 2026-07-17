# Compose compatibility gap: IPv4 IPAM allocation range

## Compose surface

`networks.<name>.ipam.config[].ip_range` for the one supported IPv4 pool.

## Docker Compose V2 behavior

Docker Compose passes `ip_range` to Docker Engine as the sub-range used for automatic container address allocation. Explicit static addresses are still validated against the parent subnet.

Reference: <https://docs.docker.com/reference/compose-file/networks/#ipam>

## Previous behavior

The normalizer retained every `ip_range` as `ipam.config.ip_range` in `unsupportedFields`. Project commands failed before creating resources.

## Ownership and minimal implementation

`container-compose` owns preserving the one IPv4 value in its normalized model, validating it before any resource side effect, and mapping it to direct and dry-run network creation. The forked runtime owns the generic typed allocation range and dynamic allocation behavior.

## Expected behavior

- One IPv4 pool may declare an optional `ip_range` together with its subnet and optional gateway.
- The range must be an IPv4 CIDR contained by the subnet and include an allocatable host address.
- Dynamic attachment allocation uses the configured range.
- Valid explicit `ipv4_address` values remain usable across the containing subnet, except the network and broadcast addresses and the configured gateway.
- IPv6 allocation ranges, IPAM driver/options, `aux_addresses`, and multiple pools of one address family remain unsupported.
