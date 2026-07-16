# Runtime gap: configure additional guest interface addresses

## Summary

The generic virtual-machine interface model has a primary IPv4/IPv6 address
but cannot carry supplementary CIDRs. Higher layers therefore cannot assign
operator-managed addresses to an already attached guest network interface.

## Expected behavior

An interface may carry zero or more additional IPv4 or IPv6 CIDRs. The guest
agent configures each additional address before it brings the link up. These
addresses must not change default-route selection or existing primary-address
behavior.

## Ownership

`apple/containerization` owns the typed interface model and guest-agent RPC.
Callers own their own configuration syntax and address-policy decisions.

## Upstream context

No matching open `apple/containerization` issue or pull request was found on
2026-07-16. `apple/container#1034` concerns complete IPv6 router-advertisement
and SLAAC support, which is broader than explicit address assignment. Its
direction remains compatible with this primitive.

## Validation expectations

- NAT, NAT-network, and TAP interfaces retain additional CIDRs.
- The guest agent adds IPv4 and IPv6-only supplementary CIDRs through the
  existing address-add RPC.
- Existing callers with no additional addresses retain current behavior.
