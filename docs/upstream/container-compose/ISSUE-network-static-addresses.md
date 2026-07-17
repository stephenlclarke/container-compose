# Compose compatibility gap: static network endpoint addresses

## Compose surface

`services.<name>.networks.<network>.ipv4_address` and
`services.<name>.networks.<network>.ipv6_address`

## Docker Compose V2 behavior

Compose passes a service endpoint's requested IPv4 or IPv6 address to the
selected network. For a Compose-managed network, the matching address must be
inside a declared IPAM subnet.

References:

- <https://docs.docker.com/reference/compose-file/services/#ipv4_address>
- <https://docs.docker.com/reference/compose-file/services/#ipv6_address>

## Previous behavior

The normalizer retained both endpoint fields, but Compose preflight rejected
them as unsupported network attachment options before creating resources.

## Ownership and minimal implementation

`container-compose` owns validation of the Compose model and safe rendering of
the runtime attachment. The local runtime bridge owns parsing, and the separate
Apple-shaped `container` handoff owns generic typed address reservation and
collision detection.

## Expected behavior

- `up`, `create`, and one-off `run` render `ip=IPv4` and `ip6=IPv6` options.
- Managed networks require a matching IPAM subnet and reject malformed,
  unspecified, delimiter-containing, and out-of-subnet values before side
  effects.
- External networks validate address syntax locally and defer subnet ownership
  and allocation checks to the runtime that owns that network.
