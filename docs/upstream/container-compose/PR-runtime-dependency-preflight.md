# Add runtime dependency preflight

## Summary

- Adds a runtime dependency preflight for Compose commands that require the installed `container` stack.
- Checks `container system version --format json` for stephenlclarke's fork-backed `container` and `containerization` provenance plus exact package-pin alignment when concrete refs are available.
- Leaves help, `version`, `config`, dry-run commands, and `build --print` available without a runtime preflight.
- Reports a clear upgrade/install message when Apple stock, missing, or mismatched components are detected.
- Points users to <https://github.com/stephenlclarke/container-compose/blob/main/INSTALL.md>.
- Adds unit coverage plus CLI smoke coverage with a fake Apple-style `container` executable.

## Rationale

`container-compose` now requires the customized `stephenlclarke/container` and `stephenlclarke/containerization` stack for runtime-backed Compose behavior. Treating full provenance/SBOM, build-check, events, logs, restart, privileged, and related surfaces as optional fork-only caveats is less useful than failing early when the installed runtime stack is wrong.

The preflight checks source/distribution provenance first, then compares the active `container` and `containerization` refs with the package metadata when the package has concrete refs. This prevents an old plugin package from running against a newer fork-backed runtime and surfacing stale unsupported-feature errors.

## Validation

```sh
swift build --disable-automatic-resolution --product compose
swift test --disable-automatic-resolution --filter ContainerPackageCompatibilityTests
make cli-smoke-built
make coverage-check
swift format lint --strict Sources/ComposePlugin/ContainerPackageCompatibility.swift Tests/ComposePluginTests/ContainerPackageCompatibilityTests.swift
markdownlint INSTALL.md docs/upstream/container-compose/ISSUE-runtime-dependency-preflight.md docs/upstream/container-compose/PR-runtime-dependency-preflight.md
git diff --check
```

## Compatibility Notes

- `container compose ps`, `up`, `run`, `exec`, `logs`, `build` execution, and other runtime-backed commands now fail early when the active `container` executable is Apple's stock package.
- `container compose version`, help output, `config`, dry-run commands, and `build --print` remain available so users can inspect a broken or mixed install.
- Runtime preflight guidance should suggest upgrading the stable `container` / `container-compose` formulae from `stephenlclarke/tap`, refreshing the `container` postinstall hook, and restarting the service; obsolete formula names should not appear in new install guidance.

## Remaining Risks

- Exact ref checks cannot prove every runtime primitive behaves correctly. They prevent mixed Apple/fork installs and stale plugin/runtime package drift; capability behavior remains covered by focused tests and runtime smoke.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `821c0e100dfaee86ccfbb8ccd9afadff9c48c55c`.
