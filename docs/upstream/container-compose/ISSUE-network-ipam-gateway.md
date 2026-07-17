# Compose compatibility gap: IPv4 IPAM gateway

## Compose surface

`networks.<name>.ipam.config[].gateway` for an IPv4 pool.

## Docker Compose V2 behavior

Docker Compose passes an explicitly configured pool gateway to Docker Engine when it creates the network.

References:

- <https://docs.docker.com/reference/compose-file/networks/#ipam>

## Previous behavior

The normalizer retained the field only as `ipam.config.gateway` in `unsupportedFields`. Project commands failed before creating resources.

## Ownership and minimal implementation

`container-compose` owns preserving the IPv4 value in its normalized model, validating it before any resource side effect, and mapping it to direct and dry-run network creation. The forked runtime owns the generic typed gateway, vmnet configuration, and allocation exclusion.

## Expected behavior

- One IPv4 pool may declare an optional gateway together with its subnet.
- The gateway must be a usable IPv4 host within that subnet.
- Compose rejects an invalid gateway and an endpoint `ipv4_address` equal to the gateway before creating a network or container.
- IPv6 gateways, IPAM driver/options, `ip_range`, `aux_addresses`, and multiple pools of one address family remain unsupported.
