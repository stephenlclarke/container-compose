# Support Docker row-format template actions

## Summary

- Replaces field-reference-only output formatting with a Compose-owned,
  row-scoped Docker template evaluator.
- Supports Docker's documented `json`, `join`, `table`, `lower`, `split`,
  `title`, `upper`, `pad`, `truncate`, and `println` functions, together with
  Go's basic `print`, `printf`, `len`, `index`, and `slice` helpers.
- Keeps data projection in each Compose command and formatting at the Compose
  boundary; no Apple runtime API or fork change is needed.
- Adds focused unit and command-path regression coverage for `ps`, `stats`,
  and `volumes`.

## Type Of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation And Context

Docker documents template functions as part of the `--format` surface. The
plugin previously accepted only a literal `{{.Field}}` action, so useful row
formats such as `{{json .}}`, `{{upper .Service}}`, and
`{{join (split .Image ":") "/"}}` were rejected even though the required
data was already available in Compose.

This is presentation policy, not a runtime primitive. The runtime continues to
return container, stats, and volume records; Compose maps those records to its
Docker-shaped rows and evaluates the requested format without widening a
matched Apple fork.

Relevant reference: [Docker's format command and log output
documentation](https://docs.docker.com/engine/cli/formatting/).

## Implementation Details

- `ComposeFormatTemplate` tokenizes actions while respecting quoted literals,
  pipelines, and parenthesized function arguments.
- Rendering keeps values typed through function evaluation so `split` can feed
  `join` and `json .` encodes the complete row deterministically.
- The stats template projection remains deliberately separate from JSON:
  `Container`, `ID`, and `Name` preserve the existing display/truncation
  policy for custom templates.
- Unknown fields still fail at command validation before discovery or stats
  sampling, and unsupported control forms and nested property paths fail before
  side effects.

## Compatibility Notes

This closes the documented row-function gap for `ps`, `stats`, and `volumes`.
The full Go-template control language (`if`, `range`, `with`, nested object
paths, and user-defined functions) is not yet represented by the flat
Docker-shaped command rows, so it remains explicitly unsupported rather than
silently producing incorrect output. `STATUS.md` records that residual gap.
The optional `printf` helper intentionally accepts only the portable `%s`,
`%v`, and `%q` verbs without width or precision modifiers.

## Validation

```sh
swift test --disable-automatic-resolution --filter ComposeFormatTemplateTests
swift test --disable-automatic-resolution --filter 'psFormatTemplate|volumesAcceptsJSONTemplateActions|statsTemplateKeepsDisplayIdentifierAliases'
make docker-compose-format-template-actions-parity
git diff --check
```

## Intended Review Delta

- `Sources/ComposeCore/ComposeFormatTemplate.swift`
- `Sources/ComposeCore/ComposeRenderHelpers.swift`
- `Sources/ComposeContainerRuntime/ContainerStatsAdapter.swift`
- `Sources/ComposePlugin/ComposeCLIHelp.swift`
- Focused Compose Core and CLI-help tests, `STATUS.md`, and `BUILD.md`

No Apple-facing pull request is intended: this slice is strictly Compose-owned
output formatting.
