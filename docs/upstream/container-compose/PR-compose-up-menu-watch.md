# Accept `up --menu --watch`

## Summary

- Allows `container compose up --menu --watch`.
- Starts interactive menu sessions with watch already enabled when the terminal can host the menu.
- Keeps Docker-compatible dry-run behavior by rendering the normal `up` create/start plan for `--menu --watch`.
- Keeps non-interactive `--watch` commands on the existing standalone watch path when the menu cannot be enabled.
- Validates missing or malformed `develop.watch` metadata before live runtime side effects.
- Updates the local Docker Compose parity script so `--menu --watch` is required parity.
- Bumps the plugin minor version to `0.2.0`.
- Updates README, status, parity docs, and upstream handoff notes.

## Type of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

Docker Compose V2 accepts `up --menu --watch` in dry-run mode. `container-compose` already supported both ingredients separately: attached menu sessions could toggle watch with `w`, and `up --watch` could run the watch engine after starting services. Rejecting the command-level combination was therefore a Compose-side false negative rather than an Apple runtime limitation.

The upstream search did not find guidance to reject this combination. This slice keeps the implementation in `container-compose` and does not require changes to Apple-backed repos.

## Implementation Details

- Adds an internal `ComposeUpOptions.menuWatch` flag for menu sessions that should start with watch already enabled.
- Removes the CLI rejection for `up --menu --watch`.
- Routes interactive `--menu --watch` through the menu-enabled `up` path with `menuWatch` set.
- Routes dry-run `--menu --watch` through the menu-enabled `up` preview path so output mirrors Docker Compose's ordinary create/start dry-run plan.
- Preserves the existing standalone watch path for non-interactive `--watch` commands when terminal conditions prevent menu ownership.
- Starts the existing watch engine in no-up mode before rendering the menu configuration, so the initial menu state is `Disable Watch`.
- Preflights selected `develop.watch` metadata before runtime side effects when live menu-watch mode is requested.
- Adds focused Swift coverage for the initial menu-watch state, missing-trigger preflight, direct option validation, and runtime dry-run acceptance.
- Updates `Tools/parity/check-compose-up-menu.sh` so Docker Compose and `container-compose` must both accept `up --menu --watch`.

## Validation

```sh
gh search issues "up --menu --watch compose" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo moby/moby --limit 30
gh search prs "up --menu --watch compose" --repo docker/compose --repo compose-spec/compose-spec --repo compose-spec/compose-go --repo moby/moby --limit 30
gh api graphql -f query='query($q:String!){ search(query:$q, type:DISCUSSION, first:10){ nodes { ... on Discussion { title url createdAt updatedAt repository { nameWithOwner } } } } }' -f q='up --menu --watch compose repo:docker/compose repo:compose-spec/compose-spec repo:compose-spec/compose-go repo:moby/moby'
docker-compose --ansi never --dry-run -p cc-menu-watch-probe -f "$tmpdir/compose.yml" up --menu --watch api
swift test --disable-automatic-resolution --filter 'upMenuWatch|upMenu|up validates incompatible recreate options'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 COMPOSE_TEST_BINARY="$PWD/.build/debug/compose" swift test --disable-automatic-resolution --filter 'runtimeDryRunUpAcceptsMenuBooleanValuesInNoStartMode|runtimeDryRunUpAcceptsMenuExitControlAndMenuWatch'
bash -n Tools/parity/check-compose-up-menu.sh
shellcheck Tools/parity/check-compose-up-menu.sh
make docker-compose-up-menu-parity
make docker-compose-cli-surface-parity
make check
make cli-smoke-built
make coverage-check
npx --yes markdownlint-cli2 README.md BUILD.md STATUS.md docs/parity/compose-cli-surface.md docs/upstream/container-compose/ISSUE-compose-up-menu.md docs/upstream/container-compose/PR-compose-up-menu.md docs/upstream/container-compose/ISSUE-compose-up-menu-exit-control.md docs/upstream/container-compose/PR-compose-up-menu-exit-control.md docs/upstream/container-compose/ISSUE-compose-up-menu-watch.md docs/upstream/container-compose/PR-compose-up-menu-watch.md
git diff --check
```

## Compatibility

This change makes `container-compose` more permissive for an option combination Docker Compose already accepts. It does not add Docker Desktop-only menu shortcuts and does not change `--watch` incompatibilities with `--detach`, `--wait`, or exit-control options.

## container-compose Checks

- [x] I updated `STATUS.md`, `PLAN.md`, `BRANCHES.md`, or `docs/upstream/` for support, branch, or runtime primitive changes, or no update is needed.
- [x] This pull request is focused on one issue or one coherent change.
- [x] I used Conventional Commits in commit messages and the pull request title.
- [ ] I signed my commits with a GitHub-supported signature method.
- [x] I removed credentials, tokens, private keys, personal data, and private registry details from code, tests, logs, and screenshots.

## Remaining Risks

- Interactive menu-watch behavior still depends on a real terminal for the menu controller. Non-interactive scripts keep the normal watch path or dry-run preview path instead of forcing terminal ownership.
