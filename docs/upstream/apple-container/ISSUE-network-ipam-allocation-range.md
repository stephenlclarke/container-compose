# Feature request: configure an IPv4 allocation range

## Summary

Network attachment allocation currently uses the allocatable host range of the configured IPv4 subnet. Generic clients cannot select a smaller CIDR for automatic address allocation while retaining the subnet for explicitly requested valid addresses.

## Expected behavior

`NetworkConfiguration` should expose an optional typed IPv4 allocation-range CIDR. It requires an IPv4 subnet, must be contained by that subnet, and must include at least one allocatable host address. When absent, automatic allocation keeps its current subnet-wide behavior.

## Ownership

`apple/container` owns persisted network configuration, command and API wiring, helper startup, and dynamic attachment allocation. Higher-level tools own their configuration syntax and policy for requesting the generic primitive.

## Related context

[apple/container#282](https://github.com/apple/container/issues/282) tracks user-controlled network addressing broadly. This request is intentionally small: it adds a typed allocator constraint without introducing a product-specific model.

## Validation expectations

- Stored configurations and runtime status round-trip with or without the optional range.
- A range without an IPv4 subnet, outside that subnet, or without an allocatable host address fails before network creation.
- The network helper receives the configured range from the API service.
- Automatically allocated attachments use the configured range, while explicitly requested valid addresses remain usable throughout the parent subnet.
