# Feature request: configure supplemental process group IDs

## Summary

Expose the existing typed supplemental group IDs in `ProcessConfiguration` through the generic process command-line surface.

## Generic behavior

- Accept repeatable numeric GIDs through `--group-add`.
- Preserve the first occurrence of every GID in argument order.
- Apply the resulting GID list to the process configuration used by both created and one-off containers.
- Keep the existing explicit primary `--gid` behavior unchanged.

## Proposed command-line surface

```console
container run --group-add 1000 --group-add 1001 alpine id
```

## Out of scope

Resolving named groups requires image filesystem and account-database inspection. This generic process primitive only accepts numeric IDs.
