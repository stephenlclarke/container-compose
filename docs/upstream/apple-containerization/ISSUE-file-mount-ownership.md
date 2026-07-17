# Feature request: private owned snapshots for regular-file mounts

## Summary

Generic container clients need to mount a regular host file with a requested
guest UID and/or GID without changing the source file on the host. This is a
runtime primitive, not Compose-specific behavior.

## Proposed behavior

- Extend regular-file mount metadata with optional numeric UID and GID.
- When either value is present, copy the source file into a private guest-side
  staging location, apply the requested ownership there, and mount that copy.
- Preserve the source file's mode on the private copy so the requested identity
  can read it when the source uses restrictive permissions.
- Leave directory mounts, special files, and mounts without ownership metadata
  on their existing live-share paths.
- Do not mutate the host source file or expose its contents in logs.

## Lifecycle and compatibility

The owned file is a creation-time snapshot. A caller recreates its container
to consume later host-file changes. Existing mounts remain live, and callers
that omit ownership metadata keep the current behavior.

This deliberately does not change directory bind mounts. In particular, it
does not work around the directory hard-link behavior tracked by
[apple/container#1937](https://github.com/apple/container/issues/1937).

## Downstream consumers

`container-compose` uses this only for generated config and secret files. It
keeps file-backed Compose sources as ordinary live read-only binds because
Docker Compose ignores their `uid` and `gid` metadata.

## Validation

- Unit coverage verifies copied file ownership, source-mode preservation, and
  unchanged host-source contents and metadata.
- Linux container coverage verifies the private snapshot path is selected only
  for a regular-file ownership request.
