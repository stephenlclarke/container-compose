# Add runtime dependency preflight

## Summary

- Adds a runtime dependency preflight for Compose commands that require the installed `container` stack.
- Checks `container system version --format json` for Stephen Clarke's fork-backed `container` and `containerization` provenance.
- Leaves help, `version`, `config`, dry-run commands, and `build --print` available without a runtime preflight.
- Reports a clear install message when Apple stock components or missing components are detected.
- Points users to <https://github.com/stephenlclarke/container-compose/blob/main/INSTALL.md>.
- Adds unit coverage plus CLI smoke coverage with a fake Apple-style `container` executable.

## Rationale

`container-compose` now requires the customized `stephenlclarke/container` and `stephenlclarke/containerization` stack for runtime-backed Compose behavior. Treating full provenance/SBOM, build-check, events, logs, restart, privileged, and related surfaces as optional fork-only caveats is less useful than failing early when the installed runtime stack is wrong.

The preflight checks source/distribution provenance instead of exact commit equality so normal Homebrew lane updates do not fail solely because a matching lane has moved. Exact pins remain visible through `container compose version --format json` and the package build metadata.

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
- Release-lane plugin packages suggest `container-release` / `container-compose-release`; other lanes suggest the main formulae.

## Remaining Risks

- Provenance-only checks cannot prove every runtime primitive exists. They prevent the most common mixed Apple/fork install failure; exact capability drift remains covered by package pins, focused tests, and runtime smoke.
