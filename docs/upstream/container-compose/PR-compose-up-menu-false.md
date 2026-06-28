# Accept `compose up --menu=false`

## Summary

This change accepts Docker Compose's explicit helper-menu disable form for `compose up`:

- Rewrites `up --menu=false`, `--menu=0`, and `--menu=no` away before Swift ArgumentParser sees the command.
- Rewrites `up --menu=true`, `--menu=1`, and `--menu=yes` to the existing `--menu` flag so interactive shortcut requests still fail with the current unsupported-feature message.
- Marks `up --menu` as partially supported in CLI help and documents the supported false form.
- Adds focused argument rewriter, plugin help/parser, Makefile smoke, and runtime dry-run coverage.

## Rationale

Docker Compose models `--menu` as an optional boolean flag and commonly invokes `up --menu=false` in non-interactive tests and scripts. This plugin previously modeled it as a plain Swift flag, so `--menu=false` failed during argument parsing before Compose loading or dry-run behavior could start.

The plugin still does not own interactive keyboard shortcuts for attached `up`, so enabling the menu remains unsupported. Accepting the explicit disable form improves compatibility without pretending the helper menu exists.

## Verification

Run focused local validation:

```sh
swift test --disable-automatic-resolution --filter 'normalizesUpMenuBooleanValueForms|doesNotRewriteUpMenuValueFormsAfterTerminator|upMenuOptionShowsPartialSupportForExplicitDisable|upMenuFalseValueParsesThroughDockerComposeRewriter'
CONTAINER_COMPOSE_RUN_RUNTIME_TESTS=1 swift test --disable-automatic-resolution --filter runtimeDryRunUpAcceptsMenuFalseValue
git diff --check
```

Before pushing the main-only compatibility slice, run the broader local gate:

```sh
make check
make cli-smoke-built
```

## Compatibility Notes

- `--menu=false` is now accepted as an explicit no-op for the unimplemented helper menu.
- Bare `--menu` and `--menu=true` remain unsupported because keyboard shortcut handling is still missing.
- The command remains partially supported until the true interactive helper menu is implemented or intentionally scoped out.
