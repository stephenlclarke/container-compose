# Pull request: add image-aware supplemental process groups

## Summary

- Add repeatable `--group-add GROUP` parsing to the shared process flags.
- Preserve numeric GIDs and group names separately in `ProcessConfiguration`.
- Resolve names in the guest-image-owning `containerization` layer against `/etc/group`, then merge the resulting GIDs with the numeric list.
- Reuse the typed process configuration for created, one-off, exec, and healthcheck processes.

## Intended review delta

The change keeps the CLI and process model generic. Only `containerization`, which already owns the selected root filesystem during Linux guest preparation, reads the image's `/etc/group`. No Compose type or Docker-specific behavior crosses into either fork.

## Commit tracking

- Containerization fork implementation: `bf487e2`.
- Containerization fork merge: `d34c67e2f0fce3ffa790630df6b803c014507560`.
- Container fork implementation: `c5625a3`.
- Container fork merge: `ff04c728133ea4ef6a0e003115acff2bee03e941`.
- No Apple remote was modified.

## Validation

```console
swift test --filter 'ParserTest/testProcessAddsSupplementalGroups'
make fmt
make check
make test
```
