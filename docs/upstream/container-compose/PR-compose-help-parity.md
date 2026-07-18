# Pull request: align Compose command HELP with implemented parity

## Summary

- Expose `container compose help` as a supported Compose-layer command.
- Mark `build`, `config`, `events`, `exec`, `ps`, `run`, `stats`, `up`, and
  `volumes` as partially supported where their actual runtime limits remain.
- Mark `exec --privileged` as partial because the current capability-only
  mapping is not Docker-complete privileged isolation.
- Update the checked CLI surface allowlist, smoke assertions, and `STATUS.md`
  counts to match rendered HELP.

## Apple-shaped implementation boundary

No fork or runtime change is required. The implementation is isolated to the
Compose command-help model, its focused Swift tests, and the compatibility
ledger. This keeps the behavior in the plugin layer, where the outer CLI cannot
intercept `container help compose`.

## Behavior contract

```console
container compose help
```

returns the Compose root help. `container help compose` remains outside the
plugin dispatch path and is intentionally not represented as a supported
command.

Each orange command/option marker identifies a specific remaining behavior
gap; the HELP output does not use green status merely because an invocation is
accepted.

## Validation

```sh
swift test --disable-automatic-resolution --filter ComposeCLIHelpTests
make cli-smoke-built
DOCKER_COMPOSE=.build/docker-reference-test/docker-compose \
  CONTAINER_COMPOSE=.build/debug/compose \
  Tools/parity/check-compose-cli-surface.sh --strict
make check
markdownlint $(git ls-files '*.md')
git diff --check
```

## Commit tracking

The implementation commit is recorded by the immediate handoff-linkage commit
after this locally validated slice. No Apple fork commit is required.
