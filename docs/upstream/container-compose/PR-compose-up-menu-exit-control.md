# Accept `up --menu` with exit-control options

## Summary

- Removes the artificial `up --menu` plus exit-control rejection.
- Runs menu log follow beside the existing exit-control waiter.
- Preserves menu detach behavior: a user detach cancels attached log ownership without forcing exit-control teardown.
- Preserves existing exit-control behavior: an exit-control result tears the project down and returns the selected or failing status.
- Updates the local Docker Compose parity script so menu plus exit-control is required parity.
- Keeps `up --menu --watch` as the remaining documented menu combination gap.
- Bumps the plugin patch version to `0.1.6`.
- Updates README, status, parity docs, and upstream handoff notes.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose V2 accepts `up --menu` with exit-control options in local dry-run mode. `container-compose` already owned both pieces separately: menu log follow and exit-control waiting/teardown. Rejecting the combination was therefore a Compose-side false negative rather than an Apple runtime limitation.

The upstream search did not find guidance to reject this combination. This slice keeps the implementation in `container-compose` and does not require changes to Apple-backed repos.

## Implementation Details

- Removed CLI and orchestrator validation that rejected `up --menu` with exit-control options.
- Added a menu operation race that follows logs while waiting for the existing exit-control path.
- Stores the exit-control status from the menu session and returns it from `compose up`.
- Leaves `up --menu --watch` rejected until a dedicated watch/menu lifecycle pass.
- Updated focused Swift tests, runtime dry-run smoke, and `Tools/parity/check-compose-up-menu.sh`. The local dry-run harness verifies Docker Compose accepts the combination and verifies `container-compose` accepts it while preserving the existing exit-control dry-run wait/down plan.

## Validation

```sh
gh search issues "up --menu abort-on-container-exit watch compose" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo moby/moby --limit 30
gh search prs "up --menu abort-on-container-exit watch compose" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo moby/moby --limit 30
gh api graphql -f query='query($q:String!){ search(query:$q, type:DISCUSSION, first:10){ nodes { ... on Discussion { title url createdAt updatedAt repository { nameWithOwner } } } } }' -f q='up --menu abort-on-container-exit watch compose repo:docker/compose repo:compose-spec/compose-spec repo:compose-spec/compose-go repo:moby/moby'
docker-compose --ansi never --dry-run --project-directory "$tmpdir" -p cc-menu-probe -f "$tmpdir/compose.yml" up --menu --abort-on-container-exit api
docker-compose --ansi never --dry-run --project-directory "$tmpdir" -p cc-menu-probe -f "$tmpdir/compose.yml" up --menu --watch api
swift test --disable-automatic-resolution --filter 'upMenu|upExitControl|upAbortOnContainer'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 COMPOSE_TEST_BINARY="$PWD/.build/debug/compose" swift test --disable-automatic-resolution --filter 'runtimeDryRunUpAcceptsMenuBooleanValuesInNoStartMode|runtimeDryRunUpAcceptsMenuExitControlAndRejectsMenuWatch'
bash -n Tools/parity/check-compose-up-menu.sh
shellcheck Tools/parity/check-compose-up-menu.sh
make docker-compose-up-menu-parity
make docker-compose-cli-surface-parity
make check
make cli-smoke-built
make coverage-check
npx --yes markdownlint-cli2 README.md BUILD.md STATUS.md docs/parity/compose-cli-surface.md docs/upstream/container-compose/ISSUE-compose-up-menu.md docs/upstream/container-compose/PR-compose-up-menu.md docs/upstream/container-compose/PR-compose-up-exit-control.md docs/upstream/container-compose/ISSUE-compose-up-menu-exit-control.md docs/upstream/container-compose/PR-compose-up-menu-exit-control.md
git diff --check
```

## Compatibility

This change makes `container-compose` more permissive for an option combination Docker Compose already accepts. It does not add Docker Desktop-only menu shortcuts and does not change `--detach`, `--wait`, `--no-start`, or `--watch` exit-control incompatibilities.

## Remaining Risks

- `up --menu --watch` still needs a dedicated parity pass because the command-level watch loop and the menu toggle loop currently own overlapping lifecycle responsibilities.
