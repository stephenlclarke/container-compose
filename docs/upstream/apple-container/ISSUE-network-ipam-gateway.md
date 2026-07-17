# Feature request: configure an IPv4 network gateway

## Summary

Network creation currently derives the IPv4 gateway from the first usable address in the subnet. Generic clients cannot choose a different valid gateway even though the vmnet network-configuration API accepts the gateway address alongside the subnet mask.

## Expected behavior

`NetworkConfiguration` should expose an optional typed IPv4 gateway. It must require an IPv4 subnet, belong to that subnet, and not use the network or broadcast address. When absent, existing default-gateway behavior must remain unchanged.

## Ownership

`apple/container` owns persisted network configuration, command/API wiring, helper startup, vmnet configuration, and preventing the gateway from being allocated to an attachment. Higher-level tools own their configuration syntax and any policy around which gateway to request.

## Related context

[apple/container#282](https://github.com/apple/container/issues/282) tracks user-controlled network addressing broadly. This request is intentionally smaller: it configures an existing vmnet primitive and does not add Docker- or Compose-specific data structures.

## Validation expectations

- Stored configurations round-trip with or without the optional gateway.
- A gateway without an IPv4 subnet, outside the subnet, or equal to the network or broadcast address fails before a network is created.
- The network helper passes the configured gateway to vmnet.
- A gateway inside the dynamic allocation range is reserved so no attachment can receive it.
