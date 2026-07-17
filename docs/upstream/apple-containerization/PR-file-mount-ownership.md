# Pull request: support private owned regular-file mount snapshots

## Summary

- Add optional ownership metadata for regular-file mounts.
- Create a private guest snapshot only when ownership is requested.
- Apply ownership in the guest without mutating the host source.

## Scope

The implementation is deliberately generic. It does not parse Compose files,
contain Docker command syntax, or change normal directory bind mounts.

## Commit tracking

- Fork implementation: `dd1173c` (`feat(mount): support owned file snapshots`)
- Fork main merge: `86593b23c77d03d7d170631bc2bfe4dd114fc6c1`
- Stephen-owned PR: <https://github.com/stephenlclarke/containerization/pull/8>

No Apple remote was pushed.

## Validation

- `make fmt`
- `make check`
- `make test` (613 tests across 81 suites)
- Guest vminitd core build validation

The runtime integration registration is included but needs a kernel image in
the Apple integration environment to execute.
