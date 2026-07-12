# Runtime dependency preflight for fork-backed Compose commands

## Summary

`container compose` runtime-backed commands should fail before project or runtime work begins when the installed `container` stack is Apple's stock package, missing stephenlclarke's fork-backed `container` / `containerization` provenance, out of sync with the exact runtime refs recorded in the plugin package metadata, or not backed by a running `container` system service.

The current Compose feature set assumes the customized stack from `stephenlclarke/tap` and a ready `container` apiserver. A stock Apple `container` install does not expose the fork-backed runtime and build primitives used by this plugin, and a stopped service reports low-level XPC failures from the first live command. Both cases need clear preflight guidance.

## Current Behavior

Runtime-backed commands check the installed package metadata first. If the components match, they also check `container system status`. A stopped or unregistered service fails before Compose model loading, image builds, container creation, or other side effects.

## Expected Behavior

- Help, `version`, `config`, dry-run commands, and `build --print` remain available without a runtime preflight so users can inspect and diagnose installs.
- Runtime-backed commands check `container system version --format json` before doing work.
- A compatible install reports `container` source `stephenlclarke/container`, distribution `custom`, `containerization` source `stephenlclarke/containerization`, and refs matching the plugin package metadata when those refs are concrete.
- If `container system version --format json` includes a `container-apiserver` row, its commit must match the concrete `container` ref recorded in the plugin package metadata. Current one-row output from a matching `container` install remains compatible.
- Incompatible, unavailable, or mismatched installs fail with a clear message that the installed components do not match the plugin's Compose functionality.
- Compatible installs then check `container system status`.
- A stopped or unregistered service fails with a clear message that the matching service is not running, including `container system start`, `brew postinstall`, and `brew services restart` guidance.
- The message includes the matching Homebrew formulae and the GitHub install guide URL: <https://github.com/stephenlclarke/container-compose/blob/main/INSTALL.md>.

## Compatibility Note

The exact-ref check is skipped for local/debug package metadata that reports `unspecified` or a moving branch name. Packaged Homebrew releases carry concrete refs and must match the active `container system version --format json` output. The API-server commit is checked only when the runtime reports an API-server component row. Service readiness is checked with `container system status` after the package metadata has matched, so a stock or mismatched install still reports install/upgrade guidance rather than service-start guidance.
