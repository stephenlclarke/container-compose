# Support `userns_mode: private` in the sandbox guest

## Problem

The Compose adapter accepted `userns_mode: host`, but truthfully rejected
`private` until the matched runtime could create and map a guest user namespace.
Docker Compose V2 accepts both values, so the adapter could not provide config
and runtime parity for the portable private mode.

## Acceptance criteria

- Preserve `userns_mode: private` in canonical config output.
- Map only `private` to the generic runtime's `--userns private` argument.
- Continue mapping `host` to no user-namespace argument, retaining the
  sandbox VM's existing namespace.
- Reject unsupported/custom values before resources are created.
- Demonstrate the identity map through a Compose YAML live test.

## Scope

This must not claim macOS host namespace access or custom UID/GID mapping
support. It requires matched Container, Containerization, and guest init-image
revisions.
