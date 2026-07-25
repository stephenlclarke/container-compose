# Pull request: complete Docker structured output templates

## Summary

Replace the flat row-format evaluator with a Compose-owned structured template
engine for `ps`, `stats`, and `volumes`. The engine keeps values typed through
evaluation, supports Docker/Go control actions and helpers, and exposes the
nested command data required for label lookup and collection traversal.

This is deliberately contained in the Compose layer. No Apple runtime API,
container model, sibling fork, or package pin changes.

## Constructible Commit

- `d2a4a426792f08826e0e816c80e6775e177ab7cc`
  `feat(format): support structured output templates`
- `af1e012fb4fad4162a1841bd9a13f80be68d9fb4`
  `fix(format): match Go template control semantics`
- `0fa6bafd119829df09da2b1555a5c463f1d41fc9`
  `fix(format): project runtime mount metadata`
- `551710612d8ca9439029efb4596e7518c429f5e0`
  `fix(format): reject invalid scalar template operations`
- `00279ef2f323bb4a3e0b76360300a0a6e9fae008`
  `fix(format): preserve table header semantics`
- `f9844e5bd3be0dce7da372cd69f9463c02ba6e2b`
  `fix(format): align labels roots and comments`

All implementation commits are signed and construct the complete code delta.
This documentation commit is intentionally separate.

## Type Of Change

- [x] Bug fix
- [x] New feature
- [ ] Breaking change
- [x] Documentation update

## Code Map

- `Sources/ComposeCore/ComposeStructuredFormatTemplate.swift`
  - lexes actions, comments, quoted literals, trim markers, and text;
  - parses and evaluates `if`, `else`, `else if`, `with`, `range`, range
    variables, pipelines, root paths, nested paths, and variables;
  - traverses arrays in source order and objects in deterministic key order;
  - validates root-row field references before command side effects.
- `Sources/ComposeCore/ComposeStructuredTemplateAnalysis.swift`
  - validates lexical variable scope before command side effects;
  - preserves repeated fields and walks all control-flow branches for command
    validation;
  - discovers `.Label` keys used by Docker's dynamic table header context.
- `Sources/ComposeCore/ComposeDockerTemplateData.swift`
  - supplies recursive array, object, lookup-object, scalar, and null values;
  - keeps display, truthiness, and JSON projection separate.
- `Sources/ComposeCore/ComposeDockerTemplateFunctionSupport.swift` and
  `ComposeDockerTemplatePrintf.swift`
  - implement typed arity checks, boolean helpers, string and collection
    helpers, JSON, and portable `%d`, `%s`, `%v`, `%q`, width, and
    left-alignment behavior.
- `Sources/ComposeCore/ComposeStructuredTemplateWhitespace.swift`
  - distinguishes whitespace-delimited trim markers from signed integer
    literals on both action boundaries.
- `Sources/ComposeCore/ComposeFormatTemplate.swift`
  - retains the public row-rendering boundary and evaluates table templates
    against Docker-style header values before rendering rows.
- `Sources/ComposeCore/ComposeRenderHelpers.swift` and
  `Sources/ComposeContainerRuntime/ContainerStatsAdapter.swift`
  - projects structured publishers, labels, mounts, networks, local-volume
    counts, and volume labels for the owning command rows;
  - supplies the exact `ps`, `stats`, and `volumes` header contexts used by
    Docker Compose.
- `Sources/ComposePlugin/ComposeCLIHelp.swift` and `STATUS.md`
  - mark `ps`, `stats`, and `volumes` supported and close the output-template
    gap without overstating unrelated lifecycle work.
- `Tests/ComposeCoreTests/ComposeFormatTemplateTests.swift`
  - covers control flow, nested/root/variable paths, deterministic traversal,
    functions, JSON, collections, `printf`, whitespace trimming, field
    extraction, malformed input, and typed failures.
- `Tests/ComposeCoreTests/ComposeStructuredFormatTemplateTests.swift`
  - isolates malformed collection, logical, trim-marker, and formatting cases
    from the successful structured evaluator suite.
- `Tests/ComposeCoreTests/ComposeFormatTemplateTableTests.swift`
  - covers duplicate columns, conditional headers, label headers, empty
    tables, legacy callers, field analysis, and variable scope.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` and
  `Tests/ComposePluginTests/ComposeCLIHelpTests.swift`
  - cover structured command rows and honest support metadata.
- `Tools/parity/fixtures/output-template/compose.yaml` and
  `Tools/parity/check-compose-format-template-actions.sh`
  - provide the committed Docker Compose v2 oracle for container publishers,
    labels, stats control flow, volume labels, duplicate and conditional table
    headers, missing labels, comment delimiters, undefined variables,
    functions, and whitespace.

## Validation

The final local verification passed on the MacBook Pro:

```sh
make swift-coverage
make check
swiftlint lint --strict --quiet \
  Sources/ComposeCore/ComposeFormatTemplate.swift \
  Sources/ComposeCore/ComposeDockerTemplateData.swift \
  Sources/ComposeCore/ComposeDockerTemplateFunctionSupport.swift \
  Sources/ComposeCore/ComposeDockerTemplatePrintf.swift \
  Sources/ComposeCore/ComposeStructuredFormatTemplate.swift \
  Sources/ComposeCore/ComposeStructuredTemplateAnalysis.swift \
  Sources/ComposeCore/ComposeRenderHelpers.swift \
  Sources/ComposeContainerRuntime/ContainerStatsAdapter.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateTableTests.swift
swiftformat --lint --swift-version 6.2 --disable trailingCommas \
  Sources/ComposeCore/ComposeFormatTemplate.swift \
  Sources/ComposeCore/ComposeDockerTemplateData.swift \
  Sources/ComposeCore/ComposeDockerTemplateFunctionSupport.swift \
  Sources/ComposeCore/ComposeDockerTemplatePrintf.swift \
  Sources/ComposeCore/ComposeStructuredFormatTemplate.swift \
  Sources/ComposeCore/ComposeStructuredTemplateAnalysis.swift \
  Sources/ComposeCore/ComposeRenderHelpers.swift \
  Sources/ComposeContainerRuntime/ContainerStatsAdapter.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateTableTests.swift
CONTAINER_COMPOSE_CONTAINER=/opt/homebrew/opt/container-current/bin/container \
CONTAINER_COMPOSE="$PWD/.build/debug/compose" \
DOCKER_COMPOSE_REFERENCE='docker compose' \
CONTAINER_COMPOSE_LIVE=1 \
  make docker-compose-format-template-actions-parity
git diff --check
```

- Swift: 1,137 tests in 28 suites passed.
- Structured template engine: 1,163/1,259 lines, 92.37%.
- `ComposeStructuredFormatTemplate.swift`: 750/814 lines, 92.14%.
- `ComposeStructuredTemplateAnalysis.swift`: 163/176 lines, 92.61%.
- `ComposeStructuredTemplateWhitespace.swift`: 18/18 lines, 100%.
- `ComposeDockerTemplateData.swift`: 81/85 lines, 95.3%.
- `ComposeDockerTemplatePrintf.swift`: 73/75 lines, 97.3%.
- `ComposeDockerTemplateFunctionSupport.swift`: 78/91 lines, 85.7%.
- Formatter table boundary: 67/68 lines, 98.53%.
- Command rendering helpers: 752/781 lines, 96.29%.
- Repository checks passed, including 167 release-controller tests, 14
  CI-helper tests, stack consistency, release consistency, licence validation,
  and credential scanning.
- The exact changed-file SwiftLint and SwiftFormat gates passed.
- The committed integration fixture passed against Docker Compose 5.3.1 and
  the Apple Current stack:
  - `container` `c65687b084b08cf4ca5fe0d7d9b5225e1843d55f`;
  - `containerization`
    `164088e02e16ed80e536d0c59822b09931d213df`;
  - `container-compose` base
    `b644c71fd0f7dd665a2a74192ab55745faafa281`.

The user explicitly waived the soak gate for this slice. Hosted CI, CodeQL,
quality, Current publication, and exact-release verification remain promotion
requirements and will be recorded before the slice closes.

## Compatibility And Risk

Existing templates use the same public formatter entry points. Structured
values are built by the command-specific presentation layer and do not escape
into a runtime SPI. Unknown root fields are still rejected before discovery or
stats sampling. Object ranges sort keys to make output deterministic across
processes. The fixed published port in the committed fixture is loopback-only
and is removed by both reference and Apple-runtime cleanup paths.

The slice changes no sibling fork. It therefore needs no Apple-facing pull
request and introduces no Apple review dependency.

## Autobot Review

The Codex review on
[pull request #147](https://github.com/stephenlclarke/container-compose/pull/147)
identified fourteen actionable compatibility cases:

- `and` and `or` now evaluate arguments left-to-right and stop before guarded
  invalid collection access;
- multi-operand `eq` now matches any trailing operand and `ne` requires exactly
  two operands;
- `{{-3}}` remains a signed integer action, while whitespace-delimited `{{- 3}}`
  and `{{3 -}}` retain trim behavior.
- `.Mounts` now projects runtime volume and bind sources instead of
  container-side destinations.
- `.LocalVolumes` counts the runtime adapter's `external-volume` records as
  local volumes.
- `range` rejects strings instead of silently iterating their characters;
- `eq` and `ne` preserve operand types and reject mixed integer/string
  comparisons instead of comparing display text;
- `len` rejects integer, boolean, and null scalars instead of fabricating
  lengths.
- undefined variables are rejected during template validation instead of
  reaching runtime rendering;
- duplicate table fields retain one header for every rendered column;
- table headers execute the same conditional template as data rows instead of
  unioning fields from mutually exclusive branches.
- missing labels render an empty string and remain false in conditionals;
- `with .`, `with $`, and their parenthesized forms retain root-field
  validation when their successful branch still evaluates the root row;
- full-action comments scan through `/* ... */`, so embedded `}}`, parentheses,
  and trim markers do not end the action early.

Commit `af1e012fb4fad4162a1841bd9a13f80be68d9fb4` fixes the first three control and
trim cases with focused template regressions. Commit
`0fa6bafd119829df09da2b1555a5c463f1d41fc9` fixes both runtime mount
projections with command-path regression coverage. Commit
`551710612d8ca9439029efb4596e7518c429f5e0` fixes the three scalar-operation
findings and extends the live Docker Compose v2 oracle to require matching
execution failures. Commit `00279ef2f323bb4a3e0b76360300a0a6e9fae008`
fixes variable validation and table-header execution, adds exact command header
contexts, and extends the live oracle to duplicate, conditional, label, stats,
and volume headers. Commit `f9844e5bd3be0dce7da372cd69f9463c02ba6e2b`
fixes missing-label semantics, root-preserving `with` analysis, and comment
scanning, with focused tests and live Docker Compose v2 checks. No autobot
finding was deferred, and every connector comment is answered with its
implementation and verification disposition.

## Documentation And Operations

- `README.md` records the refreshed, matched upstream revisions.
- `STATUS.md` records 42 supported and four partial commands.
- The critical review marks `OUT-501` complete.
- The functions-only handoff is retained as a superseded historical slice and
  points here.
- The README VHS remains live: commands are entered with `Type`/`Enter`, output
  is produced by the running commands, and the tape contains no `Replay` or
  `Marker` directives.
- Slack START:
  [message](https://xyzzytools.slack.com/archives/C0B1RNM8ZJ5/p1784973595599049).

## Review Checklist

- [x] The signed constructible implementation commit is identified.
- [x] The change is isolated to Compose presentation policy.
- [x] Unit and command-path tests cover successful and failed evaluation.
- [x] New structured formatter coverage exceeds 90%.
- [x] A committed `compose.yaml` fixture confirms Docker Compose v2 parity.
- [x] The matched Apple Current stack passes the live integration oracle.
- [x] Local repository, style, licence, consistency, and credential gates pass.
- [x] README VHS source uses typed commands and live output only.
- [ ] Hosted CI, CodeQL, and quality checks pass for the exact revision.
- [ ] Current prerelease artifacts, checksums, attestations, and live VHS pass.
- [ ] Slack END records the delivered revision and promotion evidence.
