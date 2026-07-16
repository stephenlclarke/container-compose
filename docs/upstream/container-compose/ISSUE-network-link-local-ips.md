# Compose compatibility gap: network link-local IPs

## Compose surface

`services.<name>.networks.<network>.link_local_ips`

## Docker Compose V2 behavior

Compose preserves a list of operator-managed IP addresses on a service network
attachment. Docker's engine assigns a `/16` IPv4 or `/64` IPv6 mask when the
input is a bare address.

References:

- <https://docs.docker.com/reference/compose-file/services/#link_local_ips>
- <https://cos.googlesource.com/third_party/docker/+/refs/tags/v25.0.7/libnetwork/endpoint.go>

## Previous behavior

The normalizer preserved `link_local_ips`, but Compose preflight rejected it as
an unsupported attachment option before resource creation.

## Ownership and minimal implementation

`container-compose` owns validation and delimiter-safe mapping. The local
runtime bridge owns parsing, while the Apple-shaped typed attachment and guest
address capability live in the separate Container and Containerization
handoffs.

## Expected behavior

- `up`, `create`, and one-off `run` render one `address=VALUE` option per IP.
- Invalid, unspecified, and delimiter-containing values fail before side
  effects.
- The runtime bridge applies Docker's default masks to each mapped bare IP.
