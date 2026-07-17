# Compose compatibility gap: supplemental process groups

## Compose surface

`services.<name>.group_add` accepts a list of supplemental group names or numeric IDs.

## Docker Compose V2 behavior

Docker Compose passes each `group_add` entry to Docker Engine, where names are resolved against the image account database and numeric values are supplied as GIDs.

Reference: <https://docs.docker.com/reference/compose-file/services/#group_add>

## Implemented behavior

`container-compose` separates `group_add` values into numeric GIDs and group names before service creation. Numeric IDs and names are independently de-duplicated while retaining first occurrence. The same normalized list is used by typed service creation and repeatable `container run --group-add` arguments.

The matched runtime resolves named groups from the selected guest image's `/etc/group` file, then adds the resulting GIDs to the process configuration. This keeps image-account lookup in the guest-image-owning runtime rather than teaching the Compose layer about image filesystem layout.

## Validation and boundaries

- Numeric values are accepted through the `UInt32` GID range; empty values and out-of-range numeric IDs fail before side effects.
- Named values are accepted for managed service creation and `compose run`; an absent name fails while the guest image is prepared.
- Numeric IDs are applied before name-resolved GIDs, matching the runtime's typed process model.
- This does not add group management, host account lookup, or Docker-specific identity semantics.

## Ownership

The generic image-aware primitive lives in the Stephen-owned `containerization` and `container` forks. The Apple remotes were not modified; their review-ready handoff is recorded under `docs/upstream/apple-container/`.
