# Pull request: harden container bundle storage path validation

<!-- markdownlint-disable MD013 -->

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

This change closes the remaining storage-boundary gap after
[apple/container#1735](https://github.com/apple/container/pull/1735). The
existing client-level parser is useful, but the daemon must also protect every
managed bundle filesystem access from direct API and XPC callers.

The API remains runtime-native. It validates container and volume storage
identifiers; it does not add Docker or Compose parsing, presentation, or
project-selection behavior.

Related issue draft:
[ISSUE-container-storage-path-validation.md](ISSUE-container-storage-path-validation.md).

## Commit Tracking

- Preferred upstream foundation:
  [apple/container#1735](https://github.com/apple/container/pull/1735), commit
  `00223ad3671a8370180a1886bc400ad2b5e7ee06`.
- Local upstream import:
  `16ecfd57635f0485652dc1e379d5772a0f4b9ef6` in
  `stephenlclarke/container` (`fix(storage): import daemon ID validation from
  #1735`). This must not be submitted once #1735 is present in the Apple base.
- Residual storage-boundary implementation:
  `f7aea2732701c2a0457e7e9269f4dbd8877b10bf` in
  `stephenlclarke/container` (`fix(storage): validate managed container and
  volume paths`).

This draft is not constructible while #1735 is open. After it merges, rebase
the residual implementation onto the merged revision, resolve the overlapping
entry-point checks in favor of upstream, and cut one conflict-free follow-up
commit before opening a PR.

## Implementation Details

- Added a `FilePath.Component`-backed bundle path helper that rejects empty,
  absolute, nested, current-directory, and parent-directory identifiers.
- Applied it to bundle creation, bootstrap, logs, log following, disk usage,
  export, stop cleanup, deletion, and creation-option loading.
- Validated restored configurations before adding them to the service state.
- Made volume disk accounting use the existing volume-name contract before
  deriving any storage path.
- Preserved non-throwing aggregate disk accounting by logging and skipping
  invalid persisted identifiers.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```sh
swift test --filter StoragePathTests
swift test --filter UtilityTests/testValidEntityName
swift test --filter UtilityTests/testInvalidEntityName
git diff --check
```

The storage tests reject empty, current-directory, parent-directory, absolute,
and nested identifiers while proving valid paths remain within their managed
roots. The imported upstream tests preserve the public CLI entity-name contract.

## Compatibility Notes

- Existing valid container and volume names continue to use the same paths.
- Direct callers now receive an invalid-argument error instead of causing an
  access outside the managed storage root.
- Docker and Docker Compose compatibility remains owned by `container-compose`.

## Remaining Risks

- The follow-up must be rebased after #1735 lands so the Apple PR contains only
  the residual path-boundary change.
- Storage owned by the same local user can still be modified outside the daemon;
  this change prevents caller-provided identifiers from choosing those paths.
