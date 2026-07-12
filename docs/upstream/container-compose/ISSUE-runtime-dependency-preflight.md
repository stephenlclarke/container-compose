# Runtime dependency preflight for fork-backed Compose commands

## Summary

`container compose` runtime-backed commands should fail before project or runtime work begins when the installed `container` stack is Apple's stock package, missing stephenlclarke's fork-backed `container` / `containerization` provenance, or out of sync with the exact runtime refs recorded in the plugin package metadata.

The current Compose feature set assumes the customized stack from `stephenlclarke/tap`. A stock Apple `container` install does not expose the fork-backed runtime and build primitives used by this plugin, so delayed low-level runtime errors are misleading.

## Current Gap

Before this slice, users could install or invoke `container-compose` with an Apple stock `container` binary still first on `PATH`. Runtime-backed commands would then proceed until a later operation failed with an unrelated runtime, API, or unsupported-feature message.

That failure did not clearly explain that the installed components do not match the Compose functionality in this plugin, and it did not point users at the matching install or upgrade lane.

## Expected Behavior

- Help, `version`, `config`, dry-run commands, and `build --print` remain available without a runtime preflight so users can inspect and diagnose installs.
- Runtime-backed commands check `container system version --format json` before doing work.
- A compatible install reports `container` source `stephenlclarke/container`, distribution `custom`, `containerization` source `stephenlclarke/containerization`, and refs matching the plugin package metadata when those refs are concrete.
- If `container system version --format json` includes a `container-apiserver` row, its commit must match the concrete `container` ref recorded in the plugin package metadata. Current one-row output from a matching `container` install remains compatible.
- Incompatible, unavailable, or mismatched installs fail with a clear message that the installed components do not match the plugin's Compose functionality.
- The message includes the matching Homebrew formulae and the GitHub install guide URL: <https://github.com/stephenlclarke/container-compose/blob/main/INSTALL.md>.

## Compatibility Note

The exact-ref check is skipped for local/debug package metadata that reports `unspecified` or a moving branch name. Packaged Homebrew releases carry concrete refs and must match the active `container system version --format json` output. The API-server commit is checked only when the runtime reports an API-server component row.
