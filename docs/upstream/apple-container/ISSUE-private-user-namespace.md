# Add a generic private guest user-namespace option

## Problem

The runtime can now create a private identity-mapped user namespace inside its
Linux guest, but Container lacked a persistent configuration field and generic
CLI option to request it.

## Requested behavior

- Persist a backward-compatible, default-false `privateUserNamespace` field.
- Accept `container run|create --userns host|private`.
- Map `private` to the lower runtime and leave `host` as the sandbox VM's
  existing user namespace.
- Reject values outside those two modes at the generic CLI boundary.

## Out of scope

Custom UID/GID maps, named user namespaces, macOS host namespace access,
Windows, Docker/Compose models, and inter-container namespace sharing.

## Acceptance criteria

- Old persisted configurations decode with private mode disabled.
- CLI help states the exact supported modes.
- A private container and later `exec` both observe `0 0 4294967295` in the
  guest UID map using a matching guest init image.
