# Pull request: reserve requested primary network addresses

## Summary

- Add optional typed IPv4 and IPv6 address fields to attachment configuration.
- Preserve backward-compatible decoding for older attachment data.
- Propagate the fields through the generic network client, XPC protocol, and
  isolated/custom network strategies.
- Reserve requested addresses in the existing allocation owner and return
  deterministic range, mismatch, and collision errors.

## Intended review delta

This Apple-shaped draft is constructible from `stephenlclarke/container`
commit `dc18f02c0fa8e9af391dabde19be283d4b8b648e`. It contains no
Compose-specific model, terminology, or policy.

## Implementation details

The generic API accepts already-parsed address types. IPv4 requests use the
runtime's existing allocatable host range; IPv6 requests require the configured
IPv6 subnet and are tracked by allocated address as well as attachment index.
Reusing an existing hostname must request the same addresses, so reconciliation
cannot silently change an attached container's identity.

The local CLI accepts `ip=IPv4` and `ip6=IPv6` solely as a compatibility
bridge. Those parser spellings are deliberately outside the proposed Apple API.

## Upstream context

[apple/container#282](https://github.com/apple/container/issues/282) describes
the user-facing static-address need. [apple/container#751](https://github.com/apple/container/pull/751)
is related but only parses one IPv4 spelling and does not provide the generic
dual-stack reservation semantics in this handoff.

## Validation

```sh
make fmt
make check
swift test --filter 'AttachmentAllocatorTest|ParserTest|AttachmentConfigurationTest' --disable-automatic-resolution -Xswiftc -warnings-as-errors
make test
```

## Handoff status

No Apple-owned remote has been pushed. The Stephen-owned fork implementation
is ready for Apple-maintainer review.
