# Support `--parallel` image pull and push

## Summary

- Thread the parsed root `--parallel` value into `ComposeExecutionOptions`.
- Add a bounded image-operation helper that defaults to ordered execution, honors positive limits, treats `-1` as uncapped, and rejects zero or other invalid negative values.
- Apply the helper to repeated `pull` and `push` image operations while preserving ordered dry-run output.
- Mark root `--parallel` as partially supported in help and document the exact scope.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The CLI parser accepted Docker Compose's root `--parallel` option, but orchestration ignored it and help correctly showed it as unsupported. This change closes the safe image-operation portion of that compatibility gap without changing dependency-sensitive service scheduling.

The implementation deliberately keeps dry-run output, builds, creates, starts, and lifecycle reconciliation ordered. Build planning depends on service-context build ordering, and service lifecycle parallelism needs a separate dependency-graph review.

## Implementation Details

- Added `ComposeExecutionOptions.maxParallelism`.
- Added `runImageOperations` to choose ordered execution by default and bounded task groups only when `--parallel` is explicitly set and useful.
- Suppressed per-image spinner ownership inside the parallel path and used one aggregate progress activity for the batch.
- Updated `pull` and `push` to precompute selected image references and run them through the helper.
- Updated help prose and support metadata from unsupported to partially supported.

## Docker Compose Compatibility Notes

Supported:

- Positive `--parallel` values cap concurrent repeated image pulls and pushes.
- `--parallel -1` removes the local cap for repeated image pulls and pushes.
- Invalid values fail before image side effects.

Remaining gap:

- Docker Compose may apply the global parallelism setting to additional lifecycle work. `container-compose` keeps those paths ordered until dependency and progress behavior can be changed safely.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --disable-automatic-resolution --filter 'pullHonorsConfiguredParallelImageOperationLimit|pullRejectsInvalidParallelismBeforeSideEffects|pushHonorsUnlimitedParallelImageOperations|ComposeCLIHelpTests'
```

Broader local gate:

```bash
make check
make ci
make docker-compose-parity
npx --yes markdownlint-cli README.md STATUS.md docs/parity/compose-cli-surface.md docs/upstream/container-compose/ISSUE-compose-parallel-image-operations.md docs/upstream/container-compose/PR-compose-parallel-image-operations.md
git diff --check
```

## container-compose Checks

- [x] I updated `STATUS.md` for runtime primitive changes, or no update is needed.
- [x] I updated `STATUS.md` or relevant upstream docs for newly discovered gaps, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.
