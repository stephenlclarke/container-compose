# PR: inspect macOS background registrations accurately

Related issue: [711](https://github.com/stephenlclarke/container-compose/issues/711).

## Change

The real Compose pair-installation preflight failed before any package or service mutation because some macOS login/background registrations lack the plist-specific path or program fields. The adapter now snapshots every unrelated label with optional unique path, program and type fields and preserves the before/after identity comparison. Duplicate identity fields and transport/disappearance failures still reject.

Owned Homebrew registrations retain strict canonical plist, process, executable signature and lifecycle checks. This changes only the separately hash-bound installation adapter; qualified product source, archived binaries, final notarization and immutable release assets remain unchanged.

## Validation

Six focused parser regressions plus 18 existing pair/restoration/portability cases pass (24 total). The shared installation core and frozen archive-producing checkout remain unchanged. The production installation/restoration receipt is required independently before stable promotion.
