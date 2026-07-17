# Runtime API gap: request primary network addresses

## Summary

Runtime attachment configuration currently allocates the next available IPv4
address and derives an IPv6 address from the interface MAC. Generic clients
cannot ask for a stable primary address or receive a deterministic collision
error when an address is already in use.

## Expected behavior

Attachment options should expose optional typed IPv4 and IPv6 addresses, pass
them through the existing network-client protocol, and reserve them when a
network attachment is allocated. Absent options must preserve the current
automatic allocation behavior.

## Ownership

`apple/container` owns typed attachment configuration, validation at its
network boundary, and allocation ownership. Higher-level tools own their own
configuration syntax and source-specific subnet checks.

## Upstream context

[apple/container#282](https://github.com/apple/container/issues/282) requests
static network addresses. [apple/container#751](https://github.com/apple/container/pull/751)
is an open, incomplete parser-only attempt that supports one IPv4 spelling but
does not reserve IPv6 addresses or reconcile collisions. Its direction is
related but it is not a suitable dependency.

## Validation expectations

- Existing serialized attachment data decodes without requested addresses.
- Requested IPv4 addresses are restricted to allocatable hosts in the network
  IPv4 subnet and cannot collide with another allocation.
- Requested IPv6 addresses require the network IPv6 subnet, reject zones and
  unspecified values, and cannot collide with another allocation.
- Isolated and custom-network strategies forward both typed fields unchanged.
