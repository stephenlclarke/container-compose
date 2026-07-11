# Support Timestamped Attached `compose up` Output

## Summary

`container compose up --timestamps SERVICE` should be accepted in attached mode and should render timestamped runtime log output instead of reporting the option as partially supported.

The normal attached `up` path gives one foreground service inherited terminal I/O. That path cannot synthesize Docker Compose timestamp prefixes because the plugin no longer owns stdout/stderr bytes after process handoff. The timestamped mode should therefore start the selected foreground service detached and follow its runtime logs through the existing timestamp-aware log manager.

## Acceptance Criteria

- `container compose help up` shows `--timestamps` as supported.
- `container compose up --timestamps SERVICE` runs without an unsupported
  feature error.
- Timestamped attached `up` starts the selected service detached, then follows `compose-runtime logs --follow --timestamps SERVICE_CONTAINER`.
- `--no-log-prefix` is still honored for timestamped attached `up` log rendering.
- Focused unit tests and a temp Dockerfile/compose dry-run smoke cover the behavior.

## Notes

This is a Compose-side change that reuses the runtime structured log path already used by `compose logs --timestamps --follow`. It does not require new Apple runtime APIs.
