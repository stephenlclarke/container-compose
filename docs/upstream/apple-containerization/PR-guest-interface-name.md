# Pull request: support guest interface names

## Summary

- Add an optional `guestInterfaceName` to the generic interface model.
- Carry the value through the sandbox RPC into the guest agent.
- Rename the physical interface before configuring its addresses and routes.
- Validate Linux interface-name length, reserved names, syntax, and collisions.

## Intended review delta

This draft is constructible from `stephenlclarke/containerization` commit
`bd9995b38a7e8abfc5ccfff9ea1e9f00eb895ac3`.

## Implementation details

`IpLinkSetRequest` gains an optional new-name field. The guest agent sends it
as `IFLA_IFNAME` through netlink. Interface-name resolution rejects empty names,
names longer than 15 UTF-8 bytes, whitespace, `/`, `:`, NUL, `lo`, duplicate
custom names, and names that collide with a different physical `ethN` device.

This is a generic VM-network primitive; it contains no Compose policy or
Docker-shaped configuration parsing.

## Upstream context

No matching open `apple/containerization` proposal was found on 2026-07-16.
The related `apple/container#1283` request is tracked in the sibling Container
draft and is not a duplicate.

## Validation

```sh
make check
make test
swift test --filter InterfaceTests
swift test --filter NetlinkSessionTest
```

## Handoff status

No Apple-owned remote has been pushed. The Stephen-owned fork implementation is
ready for an Apple maintainer review after the stack-level validation gate.
