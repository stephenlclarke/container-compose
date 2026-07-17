# Pull request: expose owned regular-file snapshots through bind mounts

## Summary

- Add optional `uid` and `gid` parsing for `--mount type=bind`.
- Restrict the feature to regular-file sources.
- Forward ownership metadata through `Filesystem` to containerization.

## Commit tracking

- Fork implementation: `9e2adab` (`feat(mount): support owned file snapshots`)
- Fork main merge: `486287adaf39fb5fe3e01508c6317f3da645089f`
- Stephen-owned PR: <https://github.com/stephenlclarke/container/pull/20>

No Apple remote was pushed.

## Validation

- `make fmt`
- `make check`
- `make test` (982 tests across 122 suites)
- Focused parser and runtime-bridge coverage for valid regular files and
  rejected directories

## Compatibility

Existing bind mounts remain live. Ownership requests are creation-time private
snapshots handled by containerization; callers recreate to refresh a changed
source file.
