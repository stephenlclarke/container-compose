# Pull request: carry additional interface addresses through the Linux runtime

## Summary

- Add typed `additionalIPAddresses` to attachment configuration.
- Preserve backward-compatible decoding for existing runtime data.
- Pass values through isolated and custom-network interface strategies.
- Pin the matching Containerization guest-interface implementation.

## Intended review delta

This draft is constructible from `stephenlclarke/container` commit
`678e331f13145a0be608d4dd4dbae295d48e4946`, with dependency
`containerization@a7fbf5b29a410e80e1226854670670a18a9fb07b`.

## Implementation details

The proposed Apple-shaped surface is only the typed attachment field and its
runtime propagation. The fork also accepts repeatable `address=IP[/PREFIX]` in
its local `--network` string as a temporary compatibility bridge; that parser
is deliberately not proposed as an Apple API.

Bare addresses in the local bridge use Docker's existing default masks: `/16`
for IPv4 and `/64` for IPv6. Callers that need another prefix supply it
explicitly.

## Upstream context

No matching open `apple/container` issue or pull request was found on
2026-07-16. `apple/container#1034` is related broader IPv6 work and is not a
dependency.

## Validation

```sh
make fmt
make check
swift test --filter ParserTest --disable-automatic-resolution -Xswiftc -warnings-as-errors
swift test --filter NetworkConfigurationTest --disable-automatic-resolution -Xswiftc -warnings-as-errors
swift test --filter RuntimeServiceHostsTests --disable-automatic-resolution -Xswiftc -warnings-as-errors
make test
```

## Handoff status

No Apple-owned remote has been pushed. The Stephen-owned fork implementation is
ready for Apple-maintainer review.
