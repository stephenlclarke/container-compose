# Runtime gap: name guest network interfaces

## Summary

The virtual-machine network model assigns guest interfaces from their attachment
order. Callers cannot request a stable Linux interface name, even when their
network configuration needs a predictable name after boot.

## Expected behavior

An interface model should optionally carry a guest-side name. The guest agent
should validate that name as a Linux interface name and rename the interface
before it configures addresses and routes. Absent a requested name, the current
`ethN` behavior must remain unchanged.

## Ownership

`apple/containerization` owns the generic interface model, the guest-agent RPC,
and the netlink rename operation. Higher layers own their own configuration
syntax and select an optional guest interface name.

## Upstream context

No open `apple/containerization` issue or pull request matched this primitive
when reviewed on 2026-07-16. `apple/container#1283` requests more flexible
network interface binding; it is related user demand but does not provide a
guest-interface naming primitive.

## Validation expectations

- NAT, NAT-network, and TAP interfaces carry an optional name.
- Invalid Linux names and collisions fail before VM launch.
- The guest agent emits `IFLA_IFNAME` through netlink before address and route
  setup.
- Existing callers without a name retain their current interface names.
