# Support `userns_mode: host` for the sandbox guest

## Summary

`container compose` should accept `services.<name>.userns_mode: host` when
the generic runtime already uses the sandbox VM user namespace. It must retain
the field in `compose config` output and must not claim private or custom
UID/GID-mapped user namespaces are available.

## Acceptance Criteria

- Docker Compose V2-normalized `userns_mode: host` is retained in JSON and YAML
  config output using the Compose field spelling.
- Service create, up, and one-off run accept `host` without adding an invented
  generic runtime flag.
- A live Compose YAML test confirms the running guest has the initial user
  namespace mapping (`0 0 4294967295`).
- `private` and all custom/user-mapping values fail before resource creation
  with a precise unsupported diagnostic.

## Scope

The generic runtime currently emits no OCI `user` namespace. Therefore `host`
means the sandbox VM's existing user namespace, not the macOS host. Private
user namespaces need a guest-side UID/GID-map lifecycle and are deliberately
out of scope for this Compose-only adapter slice.
