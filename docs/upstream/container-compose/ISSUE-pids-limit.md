# Compose compatibility gap: service pids_limit

## Summary

`container-compose` normalized Compose service `pids_limit` but previously rejected it as a generic memory/OOM/process runtime gap. The fork-backed runtime stack now exposes `container run/create --pids-limit`, so service `pids_limit` can be mapped directly for local Compose workflows.

## Expected Behavior

Compose files with positive `pids_limit` values should pass validation and project to runtime create/run commands. Non-positive values should remain accepted in config output and leave the local runtime limit unset, matching Docker Compose's local Engine behavior.

## Ownership

`container-compose` owns Compose model validation, command-vector rendering, dry-run output, and Docker Compose parity tests. `apple/container` owns `--pids-limit`. `apple/containerization` owns OCI `linux.resources.pids` projection.

## Validation Expectations

- `container compose config --format json` preserves the normalized service `pidsLimit`.
- `container compose --dry-run up SERVICE`, `create SERVICE`, and `run SERVICE true` render `--pids-limit`.
- Non-positive values do not render a `--pids-limit` runtime argument.
