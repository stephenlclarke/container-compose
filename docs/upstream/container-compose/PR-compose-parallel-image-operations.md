# Support `--parallel` independent image and build operations

## Summary

- Resolve `--parallel` and `COMPOSE_PARALLEL_LIMIT` into Docker Compose's unlimited-by-default behavior, with the explicit option taking precedence.
- Add a bounded engine-operation helper that honors positive limits, treats `-1` as uncapped, and rejects zero or other invalid negative values.
- Apply it to repeated `pull` and `push` image operations and dependency-safe layers of independent builds while preserving ordered dry-run output.
- Mark root `--parallel` as supported in help and document the exact scope.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The CLI parser accepted Docker Compose's root `--parallel` option, but orchestration only partially used it and its environment equivalent was absent. This change closes the safe independent-engine-operation portion of that compatibility gap without changing dependency-sensitive service lifecycle scheduling.

The implementation deliberately keeps dry-run output, creates, starts, and lifecycle reconciliation ordered. Build planning first forms dependency-safe layers: a service referenced through `additional_contexts: service:name`, or selected through `--with-dependencies`, completes before its consumer; unrelated services in a layer can run concurrently. Service lifecycle parallelism still needs a separate dependency-graph review.

## Implementation Details

- Added `ComposeExecutionOptions.maxParallelism` resolution for `COMPOSE_PARALLEL_LIMIT`, with an explicit option taking precedence and `-1` as the default.
- Added a bounded independent-engine-operation scheduler for image and build work.
- Suppressed per-image spinner ownership inside the parallel path and used one aggregate progress activity for the batch.
- Updated `pull` and `push` to precompute selected image references and run them through the helper.
- Added build dependency layers that preserve `additional_contexts: service:name` and `--with-dependencies` order while scheduling independent builds.
- Updated help prose and support metadata to supported.

## Docker Compose Compatibility Notes

Supported:

- Positive `--parallel` values cap concurrent repeated image pulls, pushes, and builds.
- `--parallel -1` removes the local cap for independent image pulls, pushes, and builds; it is also the default when no flag or environment value is supplied.
- `COMPOSE_PARALLEL_LIMIT` supplies the cap if `--parallel` is absent.
- Invalid values fail before image side effects.

Remaining gap:

- Docker Compose may apply the global parallelism setting to additional lifecycle work. `container-compose` keeps those paths ordered until dependency and progress behavior can be changed safely.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --disable-automatic-resolution --filter 'ComposeExecutionOptionsTests|pullHonorsConfiguredParallelImageOperationLimit|buildHonorsConfiguredParallelEngineCallLimit|buildLayersAdditionalContextDependenciesBeforeDependents|ComposeCLIHelpTests'
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

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `1e1674b910a06a8c4ee5956a2107801304730455`.
