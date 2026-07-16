# Pull request: carry guest interface names through the Linux runtime

## Summary

- Add optional `guestInterfaceName` to attachment configuration.
- Pass it through the isolated and custom-network runtime strategies.
- Pin the matching Containerization guest-interface implementation.
- Document and test the generic attachment behavior.

## Intended review delta

This draft is constructible from `stephenlclarke/container` commit
`180374da8b4a6e1965ebf1c9b0b4a3d7ebfccb37` and its dependency on
`containerization@df984fddf680fbc65e3c4193f11ff2cb4c77f58d`.

## Implementation details

The runtime sends the requested name to the existing interface strategy rather
than inferring a name from service or project state. This preserves a narrow,
typed boundary: Containerization validates and performs the guest rename.

The fork additionally accepts `interface=NAME` in its local `--network` value
as a temporary compatibility bridge. That parser is not the proposed Apple API;
an upstream change should retain the typed attachment field and use Apple-native
surface design.

## Upstream context

`apple/container#1283` is related demand for multi-network interface control,
but has no equivalent guest-interface name implementation. Open PR #1882 is a
routing fix and is not a dependency.

## Validation

```sh
make check
make test
swift test --filter 'ParserTest|AttachmentConfigurationTest|RuntimeServiceHostsTests'
```

## Handoff status

No Apple-owned remote has been pushed. The Stephen-owned fork implementation is
ready for the final Apple-maintainer review gate.
