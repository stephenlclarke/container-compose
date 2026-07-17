# Compose compatibility gap: IPv4 IPAM auxiliary addresses

## Compose surface

`networks.<name>.ipam.config[].aux_addresses` for the one supported IPv4 pool.

## Docker Compose V2 behavior

Docker Compose passes the mapping to Docker Engine. Its address values reserve addresses for the network driver; the mapping keys are driver-defined names.

Reference: <https://docs.docker.com/reference/compose-file/networks/#ipam>

## Fork-backed behavior

The normalizer preserves the selected IPv4 pool's values in deterministic key order. The runtime receives them as typed IPv4 allocation reservations:

- automatic allocation skips every value;
- static endpoint addresses cannot reuse a reserved value;
- invalid, out-of-subnet, and duplicate values fail before project resources are created.

The default bridge backend has no custom-driver metadata or container-facing DNS capability. Consequently, `aux_addresses` map keys are retained only long enough to choose deterministic values; they do not create DNS names. IPv6 auxiliary addresses and auxiliary addresses on an additional IPv4 pool remain unsupported and fail before resource creation.

## Ownership

`container-compose` owns Compose mapping, deterministic ordering, no-side-effects validation, and clear limits. The forked runtime owns generic typed IPv4 reservations and attachment allocation exclusion.
