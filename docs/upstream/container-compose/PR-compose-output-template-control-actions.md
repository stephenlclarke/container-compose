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
- `194e25d3f9755b7481c62d34a373375c08f1a19e`
  `fix(format): enforce structured record semantics`
- `4f28a4d5eacc301f44d65e5683a8e43f20a2510c`
  `fix(format): match Go byte and print semantics`
- `2108c6cfbb3e0da84d5e2ce877846d2b40349bd7`
  `fix(format): preserve Go record and rune formatting`
- `2628c6e32158028914c8d6e42257b877035cadad`
  `fix(format): enforce typed map index keys`
- `bae81d53665d0309b96f771dea4aac18cfd1b2f2`
  `fix(format): preserve Go operand types`
- `fcef3664b19ab7c6741d224270480abac2f1499e`
  `fix(format): preserve Go call semantics`
- `40930031b2418d873778a7cb2b1011da672f9e85`
  `fix(format): align remaining Go template semantics`
- `0057f68ed3edb5f71f62b6e79ee4083e69a0a68e`
  `fix(format): validate parenthesized root selectors`
- `b751f1951e23ddac7d223846073146e6c58f3cec`
  `fix(format): preserve logical root analysis`

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
  - resolves root-scoped `$.Label` calls against the original formatter row
    after `range` or `with` changes dot;
  - traverses arrays in source order and objects in deterministic key order;
  - validates root-row field references before command side effects.
- `Sources/ComposeCore/ComposeStructuredTemplateAnalysis.swift`
  - validates lexical variable scope before command side effects;
  - preserves repeated fields and walks all control-flow branches for command
    validation;
  - retains the first selector appended to a parenthesized root expression so
    unsupported fields cannot bypass command validation;
  - follows root values returned by `and`, `or`, and logical pipelines into
    successful `with` bodies;
  - discovers `.Label` keys used by Docker's dynamic table header context.
- `Sources/ComposeCore/ComposeStructuredTemplateCompatibilitySyntax.swift`
  - recognizes compact one- and two-variable `range` assignments without
    treating `:=` inside quoted or parenthesized expressions as declarations;
  - parses selector chains after parenthesized pipelines while retaining
    structured field types for evaluation and root-field analysis.
- `Sources/ComposeCore/ComposeDockerTemplateData.swift`
  - supplies recursive array, map, record, lookup-object, raw-byte, scalar,
    and null values;
  - distinguishes strict publisher-record fields from lenient map-key lookup;
  - renders publisher records in Go struct-field order while retaining
    `map[...]` display for ordinary objects;
  - keeps display, truthiness, and JSON projection separate while retaining
    partial UTF-8 slices for exact Go quoting.
- `Sources/ComposeCore/ComposeDockerTemplateFunctionSupport.swift` and
  `ComposeDockerTemplatePrintf.swift`
  - implement typed arity checks, boolean helpers, string and collection
    helpers, JSON, and portable `%d`, `%s`, `%v`, `%q`, width, and
    left-alignment behavior;
  - preserve Go UTF-8 byte offsets for `len`, `index`, and `slice`, Go spacing
    between adjacent non-string `print` operands, and type-aware quoted
    strings, raw bytes, runes, scalars, maps, arrays, and publisher records;
  - require typed integer offsets for indexed collections instead of coercing
    numeric strings;
  - require string or valid UTF-8 byte-string keys when indexing string-keyed
    objects and lookup objects;
  - preserve operand types for `%s` and `%d`, recursively apply verbs to
    collections and records, reproduce Go type diagnostics, and count Unicode
    scalars as Go runes when applying `printf` field widths;
  - require a typed string or valid UTF-8 byte-string `printf` format instead
    of coercing arbitrary values through display text.
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
    Docker Compose;
  - defaults absent running or created-container exit codes to typed integer
    zero, matching Docker's `.ExitCode` template value.
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
- `Tests/ComposeCoreTests/ComposeFormatTemplateCompatibilityTests.swift`
  - covers compact parenthesized control actions, empty-range declaration
    variables, strict publisher fields, scalar traversal, lenient map misses,
    UTF-8 byte helpers, `print` spacing, typed Go quoting, publisher struct
    display, decomposed and multi-scalar rune widths, and typed map keys.
- `Tests/ComposeCoreTests/ComposeFormatTemplateCallCompatibilityTests.swift`
  - covers root-scoped label rendering, field and table-key analysis, typed
    `printf` formats, compact range assignments, parenthesized selector
    chains, typed label operands, and corresponding invalid-input rejection.
- `Tests/ComposeCoreTests/ComposeFormatTemplateOperandCompatibilityTests.swift`
  - covers strict typed index and slice offsets, structured publisher joins,
    and scalar and recursive typed `printf` diagnostics.
- `Tests/ComposeCoreTests/ComposeFormatTemplateTableTests.swift`
  - covers duplicate columns, conditional headers, label headers, empty
    tables, deliberately omitted Docker headers, legacy callers, field
    analysis, and variable scope.
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` and
  `Tests/ComposePluginTests/ComposeCLIHelpTests.swift`
  - cover structured command rows and honest support metadata.
- `Tools/parity/fixtures/output-template/compose.yaml` and
  `Tools/parity/check-compose-format-template-actions.sh`
  - provide the committed Docker Compose v2 oracle for container publishers,
    labels, stats control flow, volume labels, duplicate and conditional table
    headers, missing labels, comment delimiters, undefined variables,
    compact control actions, empty-range variables, strict publisher fields,
    UTF-8 byte offsets, adjacent print operands, typed quoted values,
    publisher struct display, decomposed rune widths, non-string map-key
    rejection, structured joins, typed `printf` diagnostics, string-offset
    rejection, root-scoped labels, non-string `printf` format rejection,
    typed default exit codes, compact range declarations, parenthesized
    selectors, parenthesized and logical-root field validation, Docker's
    deliberately omitted `ps` headers, non-string label-key rejection,
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
  Sources/ComposeCore/ComposeStructuredTemplateCompatibilitySyntax.swift \
  Sources/ComposeCore/ComposeStructuredTemplateWhitespace.swift \
  Sources/ComposeCore/ComposeRenderHelpers.swift \
  Sources/ComposeContainerRuntime/ContainerStatsAdapter.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateCallCompatibilityTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateCompatibilityTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateOperandCompatibilityTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateTableTests.swift \
  Tests/ComposeCoreTests/ComposeStructuredFormatTemplateTests.swift
swiftformat --lint --swift-version 6.2 \
  Sources/ComposeCore/ComposeFormatTemplate.swift \
  Sources/ComposeCore/ComposeDockerTemplateData.swift \
  Sources/ComposeCore/ComposeDockerTemplateFunctionSupport.swift \
  Sources/ComposeCore/ComposeDockerTemplatePrintf.swift \
  Sources/ComposeCore/ComposeStructuredFormatTemplate.swift \
  Sources/ComposeCore/ComposeStructuredTemplateAnalysis.swift \
  Sources/ComposeCore/ComposeStructuredTemplateCompatibilitySyntax.swift \
  Sources/ComposeCore/ComposeStructuredTemplateWhitespace.swift \
  Sources/ComposeCore/ComposeRenderHelpers.swift \
  Sources/ComposeContainerRuntime/ContainerStatsAdapter.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateCallCompatibilityTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateCompatibilityTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateOperandCompatibilityTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateTableTests.swift \
  Tests/ComposeCoreTests/ComposeStructuredFormatTemplateTests.swift
shellcheck Tools/parity/check-compose-format-template-actions.sh
CONTAINER_COMPOSE_CONTAINER=/opt/homebrew/opt/container-current/bin/container \
CONTAINER_COMPOSE="$PWD/.build/debug/compose" \
DOCKER_COMPOSE_REFERENCE='docker compose' \
CONTAINER_COMPOSE_LIVE=1 \
  make docker-compose-format-template-actions-parity
git diff --check
```

- Swift: 1,157 tests in 31 suites passed.
- Structured template engine: 1,628/1,763 lines, 92.34%.
- `ComposeStructuredFormatTemplate.swift`: 777/838 lines, 92.72%.
- `ComposeStructuredTemplateAnalysis.swift`: 242/263 lines, 92.02%.
- `ComposeStructuredTemplateCompatibilitySyntax.swift`: 61/65 lines,
  93.85%.
- `ComposeStructuredTemplateWhitespace.swift`: 18/18 lines, 100%.
- `ComposeDockerTemplateData.swift`: 91/107 lines, 85.05%.
- `ComposeDockerTemplatePrintf.swift`: 284/298 lines, 95.30%.
- `ComposeDockerTemplateFunctionSupport.swift`: 155/174 lines, 89.08%.
- Formatter table boundary: 67/68 lines, 98.53%.
- Command rendering helpers: 751/780 lines, 96.28%.
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
processes. Publisher elements are strict records so invalid struct-field
traversal fails like Docker's Go template values, while ordinary maps retain
their existing missing-key behavior. The fixed published port in the committed
fixture is loopback-only and is removed by both reference and Apple-runtime
cleanup paths.

The slice changes no sibling fork. It therefore needs no Apple-facing pull
request and introduces no Apple review dependency.

## Autobot Review

The Codex review on
[pull request #147](https://github.com/stephenlclarke/container-compose/pull/147)
identified thirty-three actionable compatibility cases and two suggestions that
were disproved against the exact Docker Compose 5.3.1 oracle:

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
- variables declared by an empty `range` retain the original pipeline value in
  the `else` branch, matching Go template execution.
- publisher elements use strict record-field lookup, so missing publisher
  fields and attempts to traverse scalar fields fail instead of rendering
  `<no value>`.
- compact `if(...)`, `with(...)`, `range(...)`, and `else if(...)` controls are
  accepted with the same parenthesized pipelines as Docker Compose.
- `len`, `index`, and `slice` use Go string byte offsets and retain invalid
  partial UTF-8 strings for exact quoted output;
- `print` inserts spaces only between adjacent non-string operands, matching
  Go's `fmt.Sprint` behavior;
- `%q` follows the operand type for strings, raw bytes, integer runes, booleans,
  nil, arrays, maps, and publisher records, including exact Go escapes.
- publisher records render in Go struct-field order for direct and `%v`
  formatting, while ordinary objects retain map display;
- `printf` widths count Unicode scalars as Go runes instead of Swift grapheme
  clusters.
- string-keyed maps reject integer and boolean index operands instead of
  coercing their display text into plausible keys.
- indexed collections reject numeric string offsets instead of coercing them
  to integers;
- `%s` and `%d` preserve operand types, recurse through arrays, maps, and
  records, and reproduce Go type diagnostics and field-width alignment.
- `$.Label` resolves against the original root row after control actions
  change dot, including field and dynamic label-key analysis;
- `printf` rejects non-string formats instead of coercing typed operands
  through display text.
- absent running or created-container exit codes are typed integer zero, so
  numeric formatting and comparisons match Docker Compose;
- compact `$value:=...` and `$key,$value:=...` range declarations tokenize
  without requiring whitespace around Go's assignment operator;
- selectors following parenthesized pipelines, such as
  `(index .Publishers 0).TargetPort`, retain structured field lookup;
- `.Label` and `$.Label` require a string or valid UTF-8 string slice instead
  of coercing numeric operands through display text.
- selectors appended to parenthesized root expressions remain visible to
  top-level field validation, including nested parenthesized root forms.
- root values returned by `and`, `or`, or a logical pipeline keep successful
  `with` bodies in top-level field validation.

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
scanning, with focused tests and live Docker Compose v2 checks. Commit
`194e25d3f9755b7481c62d34a373375c08f1a19e` fixes empty-range declaration
variables, strict publisher-record traversal, and compact control syntax, with
focused compatibility tests and exact Docker Compose v2 rejection and output
oracles. Commit `4f28a4d5eacc301f44d65e5683a8e43f20a2510c` fixes the
three UTF-8, print, and typed-quote findings, preserves action-produced escape
sequences, and extends both focused coverage and the live Docker Compose v2
oracle. Commit `2108c6cfbb3e0da84d5e2ce877846d2b40349bd7` fixes publisher
record display and Go rune-width semantics, with focused unit coverage and
exact Docker Compose v2 and Apple Current parity. Commit
`2628c6e32158028914c8d6e42257b877035cadad` enforces typed keys for
string-keyed objects and lookup objects, with focused success and rejection
coverage plus an exact live non-string-key rejection oracle. Commit
`bae81d53665d0309b96f771dea4aac18cfd1b2f2` enforces typed integer
collection offsets and Go-compatible typed `printf` diagnostics, with focused
unit coverage and exact Docker Compose 5.3.1 and Apple Current live oracles.
Commit `fcef3664b19ab7c6741d224270480abac2f1499e` adds root-scoped
label calls and typed `printf` format enforcement, with focused rendering and
analysis coverage plus exact live success and rejection oracles.
Commit `40930031b2418d873778a7cb2b1011da672f9e85` fixes typed default exit
codes, compact range declarations, selector chains after parenthesized
pipelines, and typed label operands, with focused unit, command-path, malformed
syntax, and exact Docker Compose 5.3.1 and Apple Current live-parity coverage.
Commit `0057f68ed3edb5f71f62b6e79ee4083e69a0a68e` closes the
parenthesized-root field-validation bypass before container discovery, covers
single and nested parentheses in unit and command-path tests, and extends the
committed live fixture with the restricted-field check.
Commit `b751f1951e23ddac7d223846073146e6c58f3cec` propagates possible
root results through short-circuit `and`/`or` expressions and pipelines,
covers both root-returning and scalar-returning forms, and extends the command
and live validation regressions.

The suggestion to reject `join` for publisher records was not implemented:
Docker Compose 5.3.1 accepts `{{join .Publishers ","}}` and renders
`{127.0.0.1 8080 32768 tcp}`. The same successful behavior is now protected by
unit and committed live-parity coverage. The suggestion to invent headers for
`ExitCode`, `Health`, `LocalVolumes`, `Mounts`, `Names`, `Networks`, and
`Publishers` was also not implemented: Docker Compose 5.3.1 emits
`<no value>` for every one of those table headers. Focused unit coverage and
the committed Docker/Apple live oracle now preserve that exact behavior. No
actionable autobot finding was deferred, and every connector comment is
answered with its implementation or verified compatibility disposition.

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

- [x] The signed constructible implementation commits are identified.
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
