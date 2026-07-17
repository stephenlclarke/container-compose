# Pull request: add supplemental process group IDs

## Summary

- Add repeatable `--group-add GID` parsing to the shared process flags.
- Merge parsed GIDs with the existing numeric `--gid` fallback group and de-duplicate while preserving order.
- Reuse the existing typed `ProcessConfiguration.supplementalGroups` runtime path.

## Intended review delta

The change exposes an already-modelled process capability with a generic numeric command-line argument. It neither reads image account files nor introduces Docker-specific behavior.

## Commit tracking

- Fork implementation: `789125a008e7e7716afd27fe311c2686594b8d5b`.
- Fork merge: `77c70043a393dede0053738b4c32c486dcb0e578`.
- No Apple remote was modified.

## Validation

```console
swift test --filter 'ParserTest/testProcessAddsSupplementalNumericGroups'
make fmt
make check
make test
```
