# Support `compose attach --no-stdin` Signal Proxying

## Summary

`container compose attach --no-stdin SERVICE` should accept Docker Compose's default `--sig-proxy=true` and forward received host signals to the selected service container while following its logs.

The plugin already has an output-only attach path that follows the selected service container's runtime log stream. Before this change, that path required `--sig-proxy=false`, so the otherwise supported non-interactive attach mode rejected Docker Compose's default signal-proxy setting.

## Acceptance Criteria

- `container compose help attach` shows `--sig-proxy` as supported.
- `attach --no-stdin SERVICE` follows the selected service container logs without requiring `--sig-proxy=false`.
- `attach --no-stdin --sig-proxy=false SERVICE` continues to follow logs without installing signal forwarding.
- `attach --no-stdin --sig-proxy=true SERVICE` forwards common received signals to the selected service container through the direct lifecycle API.
- `attach --index N` keeps targeting the selected replica.
- Invalid `--sig-proxy` values fail clearly before runtime side effects.
- Stdin reattach remains unsupported until apple/container exposes an attach or reattach primitive for already-running containers.
- `--detach-keys` remains unsupported until interactive attach is available.
- Focused unit tests cover default signal forwarding, explicit signal-proxy disablement, option validation, parser behavior, and CLI help support.
- A compose.yml runtime dry-run smoke proves the built plugin accepts `attach --no-stdin` and renders the expected log-follow plan.

## Notes

This is a Compose-side compatibility improvement for the existing output-only attach path. It does not require a new apple/container interactive attach API.
