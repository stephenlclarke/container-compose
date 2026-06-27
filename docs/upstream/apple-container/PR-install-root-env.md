<!-- markdownlint-disable MD013 -->

# fix(system): honor install root environment during service start

## Template

This PR draft follows `.github/pull_request_template.md`.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

`container system start` currently defaults its `--install-root` option to `InstallRoot.defaultPath`, which is derived from `CommandLine.executablePath`. Package-manager wrappers can set `CONTAINER_INSTALL_ROOT`, but the default value bypasses that resolved path before the launchd plist is written.

For Homebrew installs where the wrapper executes a keg binary under `libexec/bin`, this causes the API server to receive an install root ending in `libexec`. It then looks for built-in plugins under `libexec/libexec/container/plugins` and fails startup with:

```text
cannot find any plugins with type network
```

The fix keeps `SystemStart` aligned with `APIServer` and plugin helpers by using `InstallRoot.path`, which already resolves `CONTAINER_INSTALL_ROOT` and falls back to `InstallRoot.defaultPath` when the environment is absent.

## What Changed

- Added `InstallRoot.resolve(environment:currentDirectory:)` so install-root resolution can be unit tested without mutating process-global environment.
- Changed `Application.SystemStart.installRoot` default from `InstallRoot.defaultPath` to `InstallRoot.path`.
- Added focused `InstallRootTests` coverage for absolute overrides, relative overrides, and fallback behavior.

## Commit Tracking

- Container code commit: `stephenlclarke/container@9f7b8af`.
- Lower runtime code commit: not required.
- Compose mapping code commit: not part of this Apple PR.

## Testing

- [x] Tested locally
- [x] Added/updated tests
- [x] Added/updated docs

Focused validation:

```bash
swift test --filter RootPathTests
```

Result:

- `RootPathTests`: 8 passing tests.

## Compatibility Notes

The explicit `container system start --install-root <path>` behavior is unchanged. The only behavior change is the default path used when the environment already supplies `CONTAINER_INSTALL_ROOT`.

When the environment is absent, `InstallRoot.path` still falls back to `InstallRoot.defaultPath`, preserving the existing source-build and direct-binary behavior.

## Remaining Risks

- Existing launchd plists generated before this fix may still contain the old wrong install-root value. Users should restart services through the fixed binary or pass `--install-root` once to rewrite the plist.
