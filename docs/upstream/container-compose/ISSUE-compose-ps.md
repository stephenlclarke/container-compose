# Fully Support `container compose ps`

## Summary

`container compose ps` should be treated as a supported command when it can list
project containers, apply service and status filters, render JSON/table/template
output, and expose `--services` / `--quiet` projections without relying on
Docker.

The previous implementation was mostly present but still marked partial in help.
Live runtime validation also exposed a hard crash when the plugin awaited direct
`ContainerClient.list(filters:)` discovery from the Compose binary. The
`container` CLI's `list --format json` boundary works reliably on the same
daemon, so this slice should use that stable JSON shape for live Compose list
operations while keeping direct single-container detail available for richer
runtime state.

## Acceptance Criteria

- `container compose help ps` reports the command as supported.
- Supported `ps` options include `--filter`, `--format`, `--services`, and
  `--status`.
- `container compose ps --format json --filter status=running SERVICE` lists a
  running Compose-managed service with project and service labels.
- `container compose ps --services --filter status=running` emits matching
  service names.
- Live discovery does not crash when listing project containers.
- Unit tests cover CLI JSON discovery mapping, hybrid live discovery, command
  failures, and malformed JSON.
- Runtime smoke tests include a build-backed Compose fixture.

## Notes

This is a Compose-side change. If the direct `ContainerClient.list(filters:)`
plugin crash is still reproducible outside Compose, track that as a separate
Apple-shaped runtime issue with a minimal reproducer.
