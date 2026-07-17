# Pull request: reserve IPv4 network addresses

## Summary

- Add `ipv4ReservedAddresses: [IPv4Address]` to network configuration and
  realized network status.
- Validate, persist, and forward reservations through the API server and helper process as repeatable `--reserve-ip` arguments.
- Exclude them from automatic and explicit attachment allocation.
- Keep older status payloads decodable when they do not contain the new field.

## Intended review delta

The feature is a generic allocation-reservation mechanism rather than a driver-specific option or a higher-layer configuration parser.

## Commit tracking

- Fork implementation: `408c89b300bba79bf0d90469bdd9cf36a9914fa0`.
- Fork merge: `5ee3649a589d56fb341d85fe9aa50d482cbfdee5`.
- No Apple remote was modified.

## Validation

```console
swift test --filter 'NetworkConfigurationTest|AttachmentAllocatorTest'
make check
make test
```

The full suite passed 978 tests on the final retry.
