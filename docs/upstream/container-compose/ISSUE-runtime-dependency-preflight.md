# Runtime dependency preflight for fork-backed Compose commands

## Summary

`container compose` runtime-backed commands should fail before project or runtime work begins when the installed `container` stack is Apple's stock package or otherwise missing Stephen Clarke's fork-backed `container` / `containerization` provenance.

The current Compose feature set assumes the customized stack from `stephenlclarke/tap`. A stock Apple `container` install does not expose the fork-backed runtime and build primitives used by this plugin, so delayed low-level runtime errors are misleading.

## Current Gap

Before this slice, users could install or invoke `container-compose` with an Apple stock `container` binary still first on `PATH`. Runtime-backed commands would then proceed until a later operation failed with an unrelated runtime, API, or unsupported-feature message.

That failure did not clearly explain that the installed Apple components do not support the Compose functionality in this plugin, and it did not point users at the matching install lane.

## Expected Behavior

- Help, `version`, `config`, dry-run commands, and `build --print` remain available without a runtime preflight so users can inspect and diagnose installs.
- Runtime-backed commands check `container system version --format json` before doing work.
- A compatible install reports `container` source `stephenlclarke/container`, distribution `custom`, and `containerization` source `stephenlclarke/containerization`.
- Incompatible or unavailable installs fail with a clear message that the installed Apple components do not support the plugin's Compose functionality.
- The message includes the matching Homebrew formulae and the GitHub install guide URL: <https://github.com/stephenlclarke/container-compose/blob/main/INSTALL.md>.

## Remaining Gap

This preflight checks fork provenance rather than exact commit equality. The package metadata and `container compose version` remain the exact pin audit tools when debugging lane drift.
