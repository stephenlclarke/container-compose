# Feature request: configure image-aware supplemental process groups

## Summary

Expose numeric supplemental GIDs and guest-image group names through the generic process command-line surface.

## Generic behavior

- Accept repeatable `--group-add GROUP` values, where `GROUP` is a numeric GID or a group name.
- Preserve the first occurrence of numeric IDs and names independently.
- Carry names in `ProcessConfiguration` until the guest root filesystem is available.
- Resolve names from the selected image root's `/etc/group`, append their GIDs, and de-duplicate before Linux process launch.
- Keep the existing explicit primary `--gid` behavior unchanged.

## Proposed command-line surface

```console
container run --group-add 1000 --group-add video alpine id
```

## Out of scope

Host account lookup, group creation, and Docker-specific identity behavior remain out of scope. Name resolution is limited to the selected guest image's existing `/etc/group`.

## Apple-shaped split

The generic process model belongs in `container`; root-image account lookup belongs in `containerization`'s Linux guest preparation. Neither change exposes Compose types or Docker-specific behavior. This is a handoff document only: no Apple remote was pushed.
