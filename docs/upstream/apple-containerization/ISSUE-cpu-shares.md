# Feature request: project Linux CPU-share weight

## Summary

Expose an optional relative CPU weight on the public Linux container
configuration and project it into OCI Linux CPU resources.

## Generic behavior

- Preserve an optional unsigned CPU-share weight on `LinuxContainer.Configuration`.
- Leave an absent value unset so the runtime keeps its normal scheduler default.
- Project a configured value to the existing OCI `LinuxCPU.shares` field.

## Rationale

OCI already models the Linux CPU-share value, but the public Containerization
configuration did not previously carry it. This is a generic Linux cgroup
resource primitive; it has no Docker or Compose surface in the runtime API.

## Upstream overlap review

No open `apple/containerization` issue or pull request matching `cpu_shares`
was found during the 2026-07-16 slice review.

## Apple-shaped split

Containerization owns only the typed configuration-to-OCI projection. Value
policy and Compose-file parsing remain in higher layers. This is a handoff
document only: no Apple remote was pushed.
