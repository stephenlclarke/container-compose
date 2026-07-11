# Support Git Repository Compose Resources

## Summary

`container compose` should accept Docker Compose Git resource syntax wherever a Compose file can be loaded: top-level `-f` / `--file`, `include.path`, and `extends.file`.

## Docker Compose References

- [docker/compose#10811](https://github.com/docker/compose/pull/10811) defines `GIT_URL#ref:subdir` loading, canonical Compose-file discovery, and checkout caching.
- [docker/compose#13331](https://github.com/docker/compose/pull/13331) rejects Git subdirectories that escape the checkout.

## Required Behavior

- Accept HTTP(S), Git, SSH URL, SCP-style, and Docker-compatible `github.com/` Git references.
- Resolve omitted refs through `HEAD` and named refs through `git ls-remote`.
- Locate `compose.yaml`, `compose.yml`, `docker-compose.yml`, or `docker-compose.yaml` when the selected resource is a directory.
- Resolve service env files, build contexts, includes, and extends relative to the selected checkout directory.
- Cache immutable commit checkouts without publishing partial clones.
- Disable interactive Git credential prompts while preserving configured non-interactive Git authentication.
- Honor `COMPOSE_EXPERIMENTAL_GIT_REMOTE=false` with a clear failure.
- Reject lexical, Windows-style, and symlink-assisted checkout escapes.
- Keep credentials out of persistent cache metadata and user-facing errors.

## Runtime Boundary

This is a Compose project-loading feature. It requires Git and `compose-go`'s resource-loader interface, but no `apple/container`, `apple/containerization`, or builder-shim API change.

## Acceptance

```sh
cd Tools/compose-normalizer && go test -race ./...
swift test --disable-automatic-resolution --filter ComposeNormalizerTests
make docker-compose-git-remote-parity
```
