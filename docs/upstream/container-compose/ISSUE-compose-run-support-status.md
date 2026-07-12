# Mark `container compose run` Supported

## Summary

`container compose run` should be shown as supported in CLI help now that the one-off container path covers the Docker Compose command surface exposed by this plugin.

The implementation already starts selected dependency services, creates scoped project resources, applies build and pull policies, supports foreground and detached execution, handles terminal handoff, maps environment, labels, capabilities, volume overrides, published ports, service ports, network aliases, user, workdir, entrypoint, explicit container names, orphan removal, and dry-run output.

## Acceptance Criteria

- `container compose help run` reports `Support: supported`.
- `run` options exposed by the help text are shown as supported.
- Existing one-off container tests continue to cover dependency selection, resource creation, build and pull behavior, terminal modes, published ports, network aliases, environment, labels, volumes, capabilities, and validation failures before runtime mutation.
- Runtime smoke continues to prove a build-backed `run --rm --no-tty` completes against the local packaged runtime.
- Top-level status documentation describes `run` as supported without duplicating release-stack refs.

## Notes

This is a Compose-side support-status correction. It does not require new Apple runtime APIs because the currently exposed `run` options are already mapped through plugin-owned orchestration and existing fork-backed runtime surfaces.
