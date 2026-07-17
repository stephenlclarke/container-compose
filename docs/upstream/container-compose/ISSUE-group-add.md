# Compose compatibility gap: supplemental process groups

## Compose surface

`services.<name>.group_add` accepts a list of supplemental group names or numeric IDs.

## Docker Compose V2 behavior

Docker Compose passes each `group_add` entry to Docker Engine, where names are resolved against the image account database and numeric values are supplied as GIDs.

Reference: <https://docs.docker.com/reference/compose-file/services/#group_add>

## Previous behavior

All `group_add` values were rejected before any Compose resource side effect because the backend CLI did not expose its typed supplemental GID process configuration.

## Ownership and minimal implementation

The runtime fork exposes repeatable numeric `--group-add` arguments and continues to pass them through its existing typed `ProcessConfiguration.supplementalGroups` path. `container-compose` validates and de-duplicates numeric values before service creation and one-off `run` execution.

## Expected behavior

- Numeric values are accepted for managed service creation and `compose run`.
- Duplicate numeric IDs retain their first occurrence and are sent once.
- A named group fails before side effects with an explicit image-aware runtime-gap message.
- Name resolution remains out of scope until the runtime offers an image-aware account-database primitive.
