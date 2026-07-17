# Pull request: configure an IPv4 allocation range

## Summary

- Add an optional typed IPv4 allocation-range CIDR to generic network configuration.
- Persist the value through the API service and pass it to the network helper.
- Constrain automatic attachment allocation to the configured range.
- Retain valid explicitly requested addresses elsewhere in the containing subnet.
- Expose the primitive through `container network create --ip-range`.

## Intended review delta

This Apple-shaped draft is constructible from `stephenlclarke/container` commit `7bf522fb808ee2517d917881421180d88d837704`, merged into its `main` as `ee63145e7f0f6d7023d6cec64b1019077b0461e4`. It contains no Compose model, terminology, or policy.

## Implementation details

The allocation range is a `CIDRv4?` associated with a `CIDRv4?` subnet, not a string option. Validation requires containment and at least one allocation-eligible host. The API service forwards `--ip-range` to the helper. The allocator keeps its full parent-subnet range for explicitly requested addresses and uses a second allocator for automatic choices, reserving each automatic address in both allocators.

## Upstream context

[apple/container#282](https://github.com/apple/container/issues/282) is related user-facing network-addressing context. The implementation is a generic allocator primitive rather than a compatibility layer.

## Validation

```sh
swift test --filter 'NetworkConfigurationTest|AttachmentAllocatorTest'
make fmt
make check
make test
```

## Handoff status

No Apple-owned remote has been pushed. The Stephen-owned fork implementation is ready for Apple-maintainer review.
