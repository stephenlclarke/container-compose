# Feature request: carry a Linux CPU-share weight to the runtime

## Summary

Expose an optional relative CPU-share weight through Container's create/run
configuration and preserve it in the Linux runtime request.

## Generic behavior

- Carry an optional unsigned CPU-share value in the Linux runtime payload.
- Assign that value to the typed `LinuxContainer.Configuration` before the OCI
  specification is built.
- Preserve absent values for backward-compatible decoding and the runtime
  default.

## Compatibility bridge

The local fork also accepts `--cpu-shares` as a temporary Docker-compatible
validation bridge. The Apple-shaped surface is the typed runtime payload and
Linux container configuration, not Compose-specific parsing or orchestration.
Zero means no explicit override; non-zero values must be at least `2`.

## Upstream overlap review

No open `apple/container` issue or pull request matching `cpu_shares` was found
during the 2026-07-16 slice review.

## Apple-shaped split

Containerization owns OCI projection, while Container owns transport to the
runtime. Compose-file parsing and command-vector rendering remain in
`container-compose`. This is a handoff document only: no Apple remote was
pushed.
