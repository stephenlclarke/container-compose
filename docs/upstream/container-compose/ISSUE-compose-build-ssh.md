# Support `compose build --ssh` and `build.ssh`

## Summary

`container compose build` should preserve Docker Compose SSH forwarding requests from both the CLI and Compose files:

- `container compose build --ssh default SERVICE`
- repeated `--ssh` values such as `--ssh default --ssh git=/tmp/git.sock`
- service `build.ssh` entries in `compose.yml`
- `container compose build --print` bake output containing the same SSH forwarding values

## Acceptance Criteria

- `compose build --ssh VALUE` is accepted and forwarded to `container build --ssh VALUE`.
- Repeated CLI SSH values are preserved.
- Service `build.ssh` values normalize into the Swift build model instead of `unsupportedFields`.
- CLI SSH entries override compose-file entries with the same SSH id.
- `build --print` emits Buildx bake `ssh` values for the selected build targets.
- Help/status metadata marks `build --ssh` as supported.
- Focused unit tests cover the parser, normalizer, command rendering, and bake rendering.
- A compose.yml runtime smoke covers `build.ssh`, CLI `--ssh`, `build --print`, default SSH agent forwarding, one explicit `id=/path/to/socket` value, and multiple distinct explicit host socket paths.

## Notes

Default SSH agent forwarding depends on the matching `stephenlclarke/container` build backend support for `container build --ssh`, plus the SSH-capable builder image from `stephenlclarke/container-builder-shim`. The backend now supports named SSH IDs and multiple explicit host Unix socket paths by forwarding those sockets into the builder container and rewriting BuildKit metadata to guest socket paths.
