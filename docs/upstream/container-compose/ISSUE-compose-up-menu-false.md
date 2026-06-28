# Accept `compose up --menu=false`

## Summary

`container compose up --menu=false SERVICE` should parse and run like Docker Compose's explicit helper-menu disable form instead of failing in CLI argument parsing.

Docker Compose exposes `--menu` as an optional boolean flag. Its default attached-mode helper menu is not implemented in this plugin yet, but the explicit disabled form is common in automated scripts and Docker Compose's own tests because it suppresses interactive shortcuts.

## Acceptance Criteria

- `container compose up --menu=false SERVICE` is accepted and follows the normal `up` path.
- `container compose up --menu=0 SERVICE` and `container compose up --menu=no SERVICE` are accepted as disabled forms.
- `container compose up --menu=true SERVICE` still reports the existing unsupported interactive-menu feature until shortcut handling is implemented.
- `container compose up --menu=false --no-start SERVICE` works in dry-run mode and renders the expected create plan.
- `container compose help up` marks `--menu` as partially supported and documents `--menu=false` as the implemented disable form.
- Focused tests cover argument rewriting, parser integration, help color/status, and a compose.yml runtime dry-run smoke.

## Notes

This does not implement Docker Compose's interactive helper menu. It removes a parser incompatibility for the explicit opt-out path while keeping the true menu request visible as a remaining partial-support item.
