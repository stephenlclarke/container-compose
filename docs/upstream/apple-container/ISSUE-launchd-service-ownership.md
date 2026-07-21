# Bug: a stale launchd label can bind a new Container installation to an old service owner

## Summary

`container` uses stable `launchd` labels for the API server, machine API,
image helper, and default vmnet helper. A matching label previously counted as
an already-registered service without confirming which plist owned it. Starting
an isolated runtime or a second installation could therefore bind a new client
to a helper from an earlier application root and wait indefinitely for an XPC
response.

## Reproduction on macOS

1. Install a signed debug runtime outside its protected source tree.
2. Start it with a temporary application root A.
3. Start the same binary with a distinct temporary application root B.
4. Before the correction, B reuses the A-owned labels. The new service's
   executable, environment, and data root do not match the caller.

This is macOS `launchd` behavior; it has no Linux guest or Windows equivalent.

## Expected behavior

- Reuse a registered label only when `launchctl print` reports the canonical
  plist path requested by the current installation.
- When the same label has a different owner plist, boot out only that service
  and bootstrap the requested plist.
- Preserve idempotent repeated starts from one application root.

## Ownership and boundary

This is a generic `apple/container` service-management defect, not a Compose
schema or Docker compatibility feature. The correction belongs in the existing
`ServiceManager` abstraction. `SystemStart` and `PluginLoader` retain their
normal `LaunchPlist` construction and delegate ownership reconciliation to
that one boundary.

## Commit tracking

- `7272c401bc134f67f64f50da5b6b5db922ebc6f7` —
  `fix(launchd): reconcile stale service ownership`.

## Validation expectations

- Focused registration tests cover missing, matching, stale, and
  symlink-canonicalized plist ownership states.
- Start two temporary app roots and confirm API server, machine API, image,
  and vmnet helper plists are all owned by the second root.
- Re-run the source-matched Docker Compose V2 parity suite because Compose is
  a runtime consumer, even though the correction adds no Compose YAML surface.
