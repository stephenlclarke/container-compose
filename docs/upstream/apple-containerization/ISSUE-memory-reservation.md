# Feature request: project a Linux memory reservation

## Summary

Expose an optional Linux soft memory reservation on the public container
configuration and project it into OCI Linux memory resources.

## Generic behavior

- Preserve an optional signed byte count on `LinuxContainer.Configuration`.
- Leave an absent value unset so the runtime keeps its normal memory policy.
- Project a configured value unchanged to the existing OCI
  `LinuxMemory.reservation` field.
- Use `Int64`, the range represented by OCI, so an out-of-range reservation is
  not silently converted or trapped during runtime-spec generation.

## Rationale

OCI already models a Linux memory reservation, but the public
Containerization configuration did not carry it. This is a generic Linux
cgroup resource primitive; it contains no Docker or Compose parsing policy.

## Upstream overlap review

No open `apple/containerization` issue or pull request matching
`mem_reservation` was found during the 2026-07-16 slice review.

## Apple-shaped split

Containerization owns only typed configuration-to-OCI projection. Value policy
and Compose-file parsing remain in higher layers. This is a handoff document
only: no Apple remote was pushed.
