# Pull request: validate container manager storage identifiers

<!-- markdownlint-disable MD013 -->

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

`ContainerManager` should reject a malformed container identifier before it
derives the managed container directory or delegates network teardown. This is
a narrow library-level storage safety improvement that leaves all Docker and
Compose option parsing in downstream clients.

Related issue draft:
[ISSUE-container-storage-path-validation.md](ISSUE-container-storage-path-validation.md).

## Commit Tracking

- `e539aa6c288afce7197a49ff73f8dfe6971ede05` in
  `stephenlclarke/containerization` (`fix(storage): validate container manager
  identifiers`).

This commit is constructible as one focused Apple pull request. It has no
dependency on a Docker or Compose layer change.

## Implementation Details

- Added `ContainerManager.containerPath(root:id:)`, using `FilePath.Component`
  and rejecting non-regular components.
- Used the helper for managed directory creation, direct container creation,
  boot-log placement, network release, and deletion.
- Validated deletion before releasing network state so malformed identifiers
  cannot reach either managed resource path.
- Added table-driven tests for empty, dot, dot-dot, absolute, nested, and valid
  identifiers.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter ContainerManagerTests/containerPath
git diff --check
```

## Compatibility Notes

- Existing single-component identifiers continue to work unchanged.
- Invalid identifiers now fail with `ContainerizationError.invalidArgument`
  before filesystem or network side effects.
- Docker and Docker Compose command parsing are not part of this API.

## Remaining Risks

- Callers that previously relied on malformed identifiers receive a normal
  validation error instead of a host-state operation.
