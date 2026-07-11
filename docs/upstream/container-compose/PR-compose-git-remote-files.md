# Support Git Repository Compose Resources

## Summary

- Registers a Git `compose-go` resource loader for config, variables, Bridge, include, and extends loading.
- Preserves remote Git references across the Swift-to-Go normalizer boundary.
- Uses Docker Compose's `URL#ref:subdir` parser, canonical filename order, cache location, non-interactive Git environment, trusted system Git executable, and disablement variable.
- Reports the checked-out Compose directory as the runtime working directory so relative env files and build contexts remain usable.
- Publishes checkouts atomically and rejects lexical, cross-platform, and symlink-assisted subdirectory escapes.
- Redacts URL credentials from cache metadata and diagnostics.
- Adds unit, race, Swift argument, include/extends, and Docker Compose parity coverage.

## Upstream Alignment

The loader is derived from [docker/compose#10811](https://github.com/docker/compose/pull/10811) and includes the traversal protection from [docker/compose#13331](https://github.com/docker/compose/pull/13331). The upstream-derived files and dependencies are isolated in their own commit; local integration and hardening remain in the Compose layer.

## User-Facing Behavior

```sh
container compose \
  -f 'https://github.com/example/project.git#main:deploy/compose' \
  config
```

The selected directory may contain any canonical Compose filename. Relative project resources resolve from the fetched directory. `COMPOSE_EXPERIMENTAL_GIT_REMOTE=false` disables Git resources explicitly. OCI Compose artifacts continue to report unsupported project-source behavior.

## Validation

```sh
cd Tools/compose-normalizer && go test -race ./... && go vet ./...
swift test --disable-automatic-resolution --filter ComposeNormalizerTests
make docker-compose-git-remote-parity
make check
```

## Release Highlight

`-f URL#ref:subdir`, Git-backed `include`, and Git-backed `extends.file` now load Compose projects with checkout-relative env/build paths and hardened caching. Upstream references: [docker/compose#10811](https://github.com/docker/compose/pull/10811), [docker/compose#13331](https://github.com/docker/compose/pull/13331).
