# Pull request: configure an IPv4 network gateway

## Summary

- Add an optional typed IPv4 gateway to generic network configuration.
- Persist the value through the API server and pass it to the network helper.
- Configure vmnet with the requested gateway while retaining the current default when it is absent.
- Exclude an in-range gateway from attachment allocation and reject it as a requested attachment address.
- Expose the same generic primitive through `container network create --gateway`.

## Intended review delta

This Apple-shaped draft is constructible from `stephenlclarke/container` commit `8152d72970e7d08b5cb777360eb787849feb6c94`, merged into its `main` as `741ca823e9fdd6992c28c1ef4005fe174e428705`. It contains no Compose model, terminology, or policy.

## Implementation details

The gateway is an `IPv4Address?` associated with a `CIDRv4?`, not a string option. Validation requires a subnet and rejects network and broadcast addresses. The vmnet helper receives an explicit `--gateway` argument from the API service, and both the reserved and allocation-only backends publish the selected gateway in network status.

The dynamic allocation range retains its existing bounds. If a configured gateway falls inside that range, the allocator reserves it before accepting attachment requests. This keeps the gateway out of both dynamic and explicitly requested attachment allocations.

## Upstream context

[apple/container#282](https://github.com/apple/container/issues/282) is related user-facing networking context. The implementation is a generic network-configuration primitive rather than a Docker compatibility layer.

## Validation

```sh
make fmt
make check
swift test --filter 'NetworkConfigurationTest|AttachmentAllocatorTest' --disable-automatic-resolution -Xswiftc -warnings-as-errors
make test
```

## Handoff status

No Apple-owned remote has been pushed. The Stephen-owned fork implementation is ready for Apple-maintainer review.
