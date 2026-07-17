# Feature request: reserve IPv4 network addresses

## Summary

Allow a network configuration to persist IPv4 host addresses that must never be allocated to an attachment.

## Generic behavior

- Reservations require an IPv4 subnet, are unique, and must be allocatable host addresses in that subnet.
- Dynamic allocation skips them, and an explicit attachment request for one
  fails as already reserved.
- The list crosses the API server, helper launch, network status, and both
  vmnet network variants as typed `IPv4Address` values.
- Existing status snapshots decode with an empty list when the field is absent.

## Proposed command-line surface

```console
container network create --subnet 192.0.2.0/24 \
  --reserve-ip 192.0.2.10 \
  --reserve-ip 192.0.2.11 app-net
```

## Out of scope

This is an allocation-control primitive. It does not introduce a driver metadata API, name resolution, or a custom network driver contract.
