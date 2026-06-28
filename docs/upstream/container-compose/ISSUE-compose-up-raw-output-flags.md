# Support Raw Attached `compose up` Output Flags

## Summary

`container compose up --no-color` and `container compose up --no-log-prefix` should be accepted in attached mode and shown as supported in CLI help.

Attached `up` currently emits raw service process output from the foreground runtime command. Because Compose does not add service prefixes or Compose-owned color to that path, these two Docker Compose log-presentation flags are already satisfied by the existing output model.

## Acceptance Criteria

- `container compose help up` shows `--no-color` as supported.
- `container compose help up` shows `--no-log-prefix` as supported.
- `container compose up --no-color --no-log-prefix SERVICE` parses without the attached-output unsupported option error.
- `container compose up --timestamps SERVICE` remains partially supported until attached foreground log following can render runtime timestamps.
- Focused tests cover help status and option parsing.

## Notes

This is a Compose-side compatibility correction. It does not require new Apple runtime APIs because it does not change how attached service stdout/stderr is collected. Timestamped attached `up` output still needs a separate implementation that can follow structured runtime logs instead of only returning foreground process output.
