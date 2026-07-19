# Support `userns_mode: host` for the sandbox guest

## Summary

`container compose` should accept `services.<name>.userns_mode: host` when
the generic runtime already uses the sandbox VM user namespace. It must retain
the field in `compose config` output without adding a synthetic runtime flag.
The follow-on private-mode work is tracked separately in
`ISSUE-userns-mode-private.md`.

## Acceptance Criteria

- Docker Compose V2-normalized `userns_mode: host` is retained in JSON and YAML
  config output using the Compose field spelling.
- Service create, up, and one-off run accept `host` without adding an invented
  generic runtime flag.
- A live Compose YAML test confirms the running guest has the initial user
  namespace mapping (`0 0 4294967295`).
- Custom/user-mapping values fail before resource creation with a precise
  unsupported diagnostic. `private` is covered by the follow-on runtime slice.

## Scope

`host` means the sandbox VM's existing user namespace, not the macOS host.
Private user namespaces were subsequently implemented through the guest
UID/GID-map lifecycle recorded in `ISSUE-userns-mode-private.md`; custom
mappings remain out of scope.
