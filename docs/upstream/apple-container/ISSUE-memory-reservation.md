# Feature request: carry a Linux memory reservation to the runtime

## Summary

Expose an optional Linux memory reservation through Container's create/run
configuration and preserve it in the Linux runtime request.

## Generic behavior

- Carry an optional signed byte count in the Linux runtime payload.
- Assign that value to the typed `LinuxContainer.Configuration` before OCI
  runtime-spec generation.
- Preserve absent values for backward-compatible decoding and the runtime
  default.

## Compatibility bridge

The local fork also accepts `--memory-reservation` as a temporary
Docker-compatible validation bridge. The Apple-shaped surface is the typed
runtime payload and Linux container configuration, not Compose-specific
parsing or orchestration. Zero leaves the reservation unset; negative and
out-of-range byte values are rejected before transport.

## Upstream overlap review

No open `apple/container` issue or pull request matching `mem_reservation` was
found during the 2026-07-16 slice review.

## Apple-shaped split

Containerization owns OCI projection, while Container owns transport to the
runtime. Compose-file parsing and Docker-compatible hard-limit relationship
validation remain in `container-compose`. This is a handoff document only: no
Apple remote was pushed.
