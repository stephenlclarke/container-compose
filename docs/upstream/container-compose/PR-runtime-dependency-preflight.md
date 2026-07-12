# Add runtime dependency preflight

## Summary

- Adds a runtime dependency preflight for Compose commands that require the installed `container` stack.
- Checks `container system version --format json` for stephenlclarke's fork-backed `container` and `containerization` provenance plus exact package metadata alignment when concrete refs are available.
- Checks `container system status` after package metadata matches so a stopped or unregistered service fails before Compose model loading or build/create side effects.
- Leaves help, `version`, `config`, dry-run commands, and `build --print` available without a runtime preflight.
- Reports a clear upgrade/install message when Apple stock, missing, or mismatched components are detected.
- Reports clear service-start guidance when the matching runtime package is installed but the `container` system service is not ready.
- Points users to <https://github.com/stephenlclarke/container-compose/blob/main/INSTALL.md>.
- Adds unit coverage plus CLI smoke coverage with fake Apple-style and stopped-service `container` executables.

## Rationale

`container-compose` now requires the customized `stephenlclarke/container` and `stephenlclarke/containerization` stack for runtime-backed Compose behavior. Treating full provenance/SBOM, build-check, events, logs, restart, privileged, and related surfaces as optional fork-only caveats is less useful than failing early when the installed runtime stack is wrong.

The preflight checks source/distribution provenance first, then compares the active `container` and `containerization` refs with the package metadata when the package has concrete refs. This prevents an old plugin package from running against a newer fork-backed runtime and surfacing stale unsupported-feature errors.

After the package metadata matches, the preflight checks `container system status`. That catches the stopped-service shape before `container compose -f examples/compose.yml up` reaches `container build` and reports a raw XPC connection failure.

## Validation

```sh
swift build --disable-automatic-resolution --product compose
swift test --disable-automatic-resolution --filter ContainerPackageCompatibilityTests
swift test --disable-automatic-resolution --filter ComposeProgress
make cli-smoke-built
make coverage-check
swiftformat Sources/ComposeCore/ComposeProgress.swift Tests/ComposeCoreTests/ComposeProgressTests.swift --lint --swift-version 6.2
swiftlint lint --strict --quiet Sources/ComposeCore/ComposeProgress.swift Tests/ComposeCoreTests/ComposeProgressTests.swift
markdownlint INSTALL.md docs/upstream/container-compose/ISSUE-runtime-dependency-preflight.md docs/upstream/container-compose/PR-runtime-dependency-preflight.md
git diff --check
```

## Compatibility Notes

- `container compose ps`, `up`, `run`, `exec`, `logs`, `build` execution, and other runtime-backed commands now fail early when the active `container` executable is Apple's stock package.
- The same runtime-backed commands fail early when the matching `container` package is installed but the apiserver is stopped, missing from launchd, or otherwise not ready.
- `container compose version`, help output, `config`, dry-run commands, and `build --print` remain available so users can inspect a broken or mixed install.
- Runtime preflight guidance should suggest upgrading the stable `container` / `container-compose` formulae from `stephenlclarke/tap`, refreshing the `container` postinstall hook, and restarting the service; obsolete formula names should not appear in new install guidance.
- Current one-row `container system version --format json` output is sufficient when the `container` row matches the package refs. If a `container-apiserver` row is present, its commit is checked for stale service detection.

## Remaining Risks

- Exact ref checks cannot prove every runtime primitive behaves correctly. They prevent mixed Apple/fork installs and stale plugin/runtime package drift; capability behavior remains covered by focused tests and runtime smoke. Stale API-server detection depends on the runtime reporting an API-server component row. Service readiness depends on `container system status`, which is intentionally a coarse ready/not-ready gate rather than a per-capability probe.

## Commit Tracking

- Primary implementation commit in `stephenlclarke/container-compose`:
  `821c0e100dfaee86ccfbb8ccd9afadff9c48c55c`.
