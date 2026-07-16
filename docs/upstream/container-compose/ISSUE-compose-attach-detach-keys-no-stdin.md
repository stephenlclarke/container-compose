# Accept `compose attach --no-stdin --detach-keys`

## Summary

`container compose attach --no-stdin --detach-keys=ctrl-x SERVICE` should use the supported output-only attach path instead of failing on detach-key validation.

Docker Compose accepts `--detach-keys` as an attach option. This plugin cannot implement interactive detach handling until `apple/container` exposes a stdin/stdout/stderr reattach primitive, but the option is irrelevant when `--no-stdin` has already selected log-follow output mode. The exact runtime boundary and required Apple-shaped primitive are documented in [ISSUE-attach-stream-reattach.md](../apple-container/ISSUE-attach-stream-reattach.md) and tracked by [apple/container#378](https://github.com/apple/container/issues/378).

## Acceptance Criteria

- `container compose attach --no-stdin --detach-keys=ctrl-x SERVICE` follows the same log output path as `attach --no-stdin SERVICE`.
- `container compose attach --detach-keys=ctrl-x SERVICE` still reports the interactive attach runtime gap.
- `container compose attach --no-stdin --sig-proxy=false --detach-keys=ctrl-x SERVICE` still disables signal proxying.
- `container compose help attach` marks `--detach-keys` as partially supported and documents the `--no-stdin` no-op behavior.
- Focused tests cover attach validation, parser integration, help color/status, Makefile smoke, and compose.yml runtime dry-run behavior.

## Notes

This does not add interactive attach support. It only accepts a harmless option value on the already-supported output-only attach path. Do not replace the missing reattach primitive with `exec`, `tmux`, or log replay: those do not reconnect to the original init process or preserve Docker-compatible terminal semantics.
