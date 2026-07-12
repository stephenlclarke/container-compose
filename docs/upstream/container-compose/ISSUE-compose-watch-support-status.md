# Mark `container compose watch` Supported

## Summary

`container compose watch` should be shown as supported in CLI help now that the local watch engine covers the Docker Compose develop workflow exposed by the command.

The implementation already validates `develop.watch` metadata, applies optional initial sync, polls watched paths, syncs changed files into service containers, removes deleted synced files, runs `sync+exec` hooks, restarts services, rebuilds services, prunes images after rebuilds, and shares the same initial `up` option model when invoked through `compose up --watch`.

## Acceptance Criteria

- `container compose help watch` reports `Support: supported`.
- `watch` options `--no-up`, `--prune`, and `--quiet` are shown as supported.
- Existing watch tests continue to cover dry-run planning, initial sync, sync+exec, delete propagation, rebuild/prune, initial up option propagation, missing trigger validation, and malformed trigger validation.
- `compose up --watch` continues to reject incompatible `--detach` and `--wait` combinations.
- Top-level status documentation describes `watch` as supported without duplicating release-stack refs.

## Notes

This is a Compose-side support-status correction. It does not require new Apple runtime APIs because the existing file sync, exec, restart, rebuild, and image prune paths already use supported plugin-owned orchestration boundaries.
