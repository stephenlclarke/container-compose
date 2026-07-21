# Bug: `container copy` rejects colons in guest paths

## Summary

`container copy` rejects a valid container reference when the POSIX guest path
contains `:`. Timestamped names such as
`/var/log/app-2026-07-20T10:30:00.log` are legal on Linux guests, but the
previous parser split at every colon and rejected the result before issuing a
copy request.

## Reproduction

```console
container run -d --name cpbox alpine \
  sh -c 'echo hi > "/var/log/app-2026-07-20T10:30:00.log"; sleep 300'
container copy cpbox:/var/log/app-2026-07-20T10:30:00.log ./out.log
```

Before the fix, the second command reports `invalid path given`.

## Expected behavior

The first `:` separates the container identifier from an absolute guest path.
Every later colon belongs to the guest path, matching `docker cp` behavior.

## Ownership and boundary

This is a generic `apple/container` CLI parser defect, not a Compose-file
feature. Compose does not model or emit `container copy` invocations, so the
runtime owns the behavioral change and Compose only pins the corrected runtime
revision.

## Upstream context

[apple/container#1969](https://github.com/apple/container/issues/1969)
documents the macOS reproduction and expected Docker-compatible semantics.

## Commit tracking

- `f03ae577d1c45e31ee6934cb020addb80334cf2d` —
  `fix(copy): preserve colons in container paths`

## Validation expectations

- Parser coverage must retain every character after the first `:`.
- A macOS CLI integration test must copy a colon-named guest file to the host.
