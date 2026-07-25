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
- `53a3bcf7253bc0ac30550731f92c8437a1c31c56`
  `fix(format): support else-with continuations`
- `e6560365bc13e61a4d861a138fb5a8a753f7693f`
  `fix(format): support piped label calls`
- `2c7b92c9677ec720f569156b4c111ecb595806d1`
  `fix(format): preserve piped label headers`
- `fe952873826f3b2b896eb61bae4c52ba77b33e6a`
  `fix(format): propagate constant label headers`
- `6f5ab6aba03ba66eee8625db178af6e95eb16f8e`
  `fix(format): align logical and UTF-8 helpers`
- `130ed4d91b2e3402e702d6d3ba3a265d92d8dd2b`
  `fix(format): preserve raw Go string helpers`
- `fce7edbadf8acfc4bf7b410d2f116d4e5f5ca0fa`
  `fix(format): preserve exact Go output semantics`
- `4fbd1b26023c873cc006c69a8de42e6c10979d1d`
  `fix(format): preserve Go trim whitespace`
- `3fe67c044ead24cca8e7c0ee2dd2afb125772a6c`
  `fix(format): preserve Go root and range semantics`
- `555dfb0ec739bb2a745d02af000d3b3ddf1f5344`
  `fix(format): restrict action whitespace to Go syntax`
- `e63293cce41444f4e44e6aa6f2bf1ad8d099690b`
  `fix(format): reject possible root ranges`
- `65c03e127348fd3246d6f90f92428cb9583d2727`
  `fix(format): accept CRLF action whitespace`
- `004ed0a65e53d90b06861c67e30cdaff5f05dcb7`
  `fix(format): defer conditional root range rejection`
- `0390a85d2952bd82e50fb98219c9207a39664377`
  `fix(format): preserve valid bytes in template JSON`

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
  - parses and renders `if`, `else`, `else if`, `with`, `else with`,
    `range`, range variables, pipelines, root paths, nested paths, and
    variables;
  - accepts shorthand continuations only for their matching Go control
    actions: `else if` after `if` and `else with` after `with`;
  - accepts `.Label` and root-scoped `$.Label` as ordinary pipeline functions
    while preserving typed argument and exact arity validation;
  - resolves root-scoped `$.Label` calls against the original formatter row
    after `range` or `with` changes dot;
  - traverses arrays in source order and objects in deterministic key order;
  - traverses positive integer ranges as `0..<value`, treats non-positive
    integer ranges as empty, and rejects their unsupported two-variable form;
  - delegates raw Go string operations without converting invalid UTF-8 byte
    sequences back through Swift `String`;
  - validates root-row field references before command side effects.
- `Sources/ComposeCore/ComposeStructuredTemplateEvaluation.swift`
  - isolates typed expression evaluation from parsing and rendering;
  - carries root provenance with each value selected by direct paths,
    parenthesized expressions, `and`, `or`, pipelines, and `with`;
  - rejects a range only when row evaluation actually selects the root,
    allowing a nonempty publisher collection to win before a root fallback;
  - marks collection entries and declared range variables as non-root without
    relying on structural equality with the formatter row.
- `Sources/ComposeCore/ComposeDockerTemplateStringSupport.swift`
  - isolates raw Go string and byte-string conversion from the evaluator;
  - splits empty separators after each valid UTF-8 sequence and each invalid
    byte, matching Go's `utf8.DecodeRune` progression;
  - finds non-empty separators and preserves raw bytes through `split`,
    `join`, and `truncate`.
- `Sources/ComposeCore/ComposeStructuredTemplateAnalysis.swift`
  - validates lexical variable scope before command side effects;
  - preserves repeated fields and walks all control-flow branches for command
    validation;
  - retains the first selector appended to a parenthesized root expression so
    unsupported fields cannot bypass command validation;
  - follows ordered truthy-root, truthy-non-root, and falsey outcomes through
    `and`, `or`, and logical pipelines so a successful `with` body is
    root-scoped only when every reachable truthy result is the root;
  - discovers direct and pipeline-fed `.Label` keys used by Docker's dynamic
    table header context;
  - evaluates constant label-key pipelines through the same typed helper path
    as row rendering, including `print`, `printf`, `upper`, `lower`, `title`,
    `pad`, and `truncate`;
  - retains separate computed lookup keys and source-literal display keys so
    transformed label lookup and Docker's table-header spelling both match.
  - rejects `index` and `len` when their first operand retains the root
    formatter row, so root map-like access cannot bypass command field
    validation;
  - rejects attempts to range over expressions whose only reachable truthy
    result is the root formatter row before command side effects, while
    deferring mixed logical fallbacks until row evaluation selects a result;
  - rejects statically known two-variable integer ranges.
- `Sources/ComposeCore/ComposeStructuredTemplateLookup.swift`
  - isolates Compose-owned field and label lookup policy from parsing and
    evaluation;
  - preserves strict record fields, lenient map keys, missing-label empty
    strings, and root-versus-dot label selection.
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
    partial UTF-8 slices for exact Go quoting and exact output bytes;
  - JSON-encodes byte strings incrementally so valid UTF-8 scalars survive
    while each invalid subsequence becomes Docker's `\ufffd` escape.
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
  - treat the lookup-object display used by `.Labels` as its generic Go string
    while preserving `.Label` as the dedicated key-lookup surface;
  - preserve invalid UTF-8 bytes through direct `%s` and `%v` output;
  - require a typed string or valid UTF-8 byte-string `printf` format instead
    of coercing arbitrary values through display text.
- `Sources/ComposeCore/ComposeDockerTemplatePrintSupport.swift`
  - isolates exact-byte `print`, `println`, and `printf` output from parsing and
    retains Go spacing rules without converting through Swift `String`.
- `Sources/ComposeCore/ComposeStructuredTemplateWhitespace.swift`
  - distinguishes whitespace-delimited trim markers from signed integer
    literals on both action boundaries;
  - recognizes Swift's combined CRLF grapheme as the same two Go action
    whitespace characters;
  - limits marker recognition and adjacent trimming to Go's ASCII space, tab,
    carriage-return, and newline set so literal non-ASCII whitespace survives;
  - applies the same four-character set to action boundaries, control
    separators, variables, pipeline segments, and range declarations so
    non-Go whitespace is rejected as syntax while quoted values retain it.
- `Sources/ComposeCore/ComposeFormatTemplate.swift`
  - retains the public row-rendering boundary and evaluates table templates
    against Docker-style header values before rendering rows;
  - adds exact-byte row joining, table padding, and output dispatch while
    retaining the existing String API for compatible callers.
- `Sources/ComposeCore/ComposeRenderHelpers.swift` and
  `Sources/ComposeContainerRuntime/ContainerStatsAdapter.swift`
  - projects structured publishers, labels, mounts, networks, local-volume
    counts, and volume labels for the owning command rows;
  - supplies the exact `ps`, `stats`, and `volumes` header contexts used by
    Docker Compose;
  - emits valid UTF-8 through the existing text callback and partial UTF-8
    through the byte callback for `ps`, `stats`, and `volumes`;
  - defaults absent running or created-container exit codes to typed integer
    zero, matching Docker's `.ExitCode` template value.
- `Sources/ComposeRuntimeSPI/ComposeRuntimeCollaborators.swift`
  - adds an optional exact-byte stats-output capability while preserving the
    existing stats-manager protocol for external implementations.
- `Sources/ComposePlugin/ComposeCLIHelp.swift` and `STATUS.md`
  - mark `ps`, `stats`, and `volumes` supported and close the output-template
    gap without overstating unrelated lifecycle work.
- `Tests/ComposeCoreTests/ComposeFormatTemplateTests.swift`
  - covers control flow, nested/root/variable paths, deterministic traversal,
    functions, JSON, collections, `printf`, whitespace trimming, field
    extraction, positive and non-positive integer ranges, one-variable integer
    declarations, root collection-operation rejection, `else with` chains,
    invalid cross-control shorthand, malformed input, and typed failures.
- `Tests/ComposeCoreTests/ComposeStructuredFormatTemplateTests.swift`
  - isolates malformed collection, logical, trim-marker, and formatting cases
    from the successful structured evaluator suite;
  - accepts CRLF between field and control tokens and around trim markers;
  - renders a logical publisher range when the collection is nonempty and
    rejects the same expression when an empty collection selects its root
    fallback;
  - rejects non-breaking spaces at action, control, and trailing-expression
    boundaries while preserving the same character inside quoted Go strings.
- `Tests/ComposeCoreTests/ComposeFormatTemplateCompatibilityTests.swift`
  - covers compact parenthesized control actions, empty-range declaration
    variables, strict publisher fields, scalar traversal, lenient map misses,
    UTF-8 byte helpers, `print` spacing, typed Go quoting, publisher struct
    display, decomposed and multi-scalar rune widths, invalid partial UTF-8
    splitting and joining, negative truncation, and typed map keys.
- `Tests/ComposeCoreTests/ComposeDockerTemplateJSONTests.swift`
  - proves partial invalid UTF-8 retains its valid prefix and emits `\ufffd`;
  - proves an already-valid replacement scalar remains literal JSON text.
- `Tests/ComposeCoreTests/ComposeFormatTemplateCallCompatibilityTests.swift`
  - covers root-scoped label rendering, field and table-key analysis, typed
    `printf` formats, compact range assignments, parenthesized selector
    chains, typed label operands, root and nested pipeline-fed labels, chained
    helpers, label headers after constant string functions, nested constant
    expressions, control-flow traversal, invalid static expressions, exact
    label arity, and corresponding invalid-input rejection.
- `Tests/ComposeCoreTests/ComposeFormatTemplateOperandCompatibilityTests.swift`
  - covers strict typed index and slice offsets, structured publisher joins,
    and scalar and recursive typed `printf` diagnostics.
- `Tests/ComposeCoreTests/ComposeFormatTemplateTableTests.swift`
  - covers duplicate columns, conditional headers, label headers, empty
    tables, deliberately omitted Docker headers, legacy callers, field
    analysis, and variable scope.
- `Tests/ComposeCoreTests/ComposeFormatTemplateRawOutputTests.swift` and
  `ComposeFormatTemplateStructuredValueTests.swift`
  - cover every structured output value, `.Labels` through generic Go string
    helpers, direct and formatted partial UTF-8, exact-byte row joining, raw
    table padding, label headers, and decomposed structured-value assertions.
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
    `else with` output through `ps`, `stats`, and `volumes`, functions, and
    whitespace, plus root and nested pipeline-fed labels and invalid extra
    label arguments and table label keys carried through `print`, `printf`,
    `upper`, `lower`, `title`, `pad`, and `truncate`.
  - verifies ordered logical publisher selection, empty-separator and
    empty-input splitting, partial UTF-8 byte truncation and splitting, and
    negative truncation rejection;
  - verifies positive, zero, and negative integer ranges, one-variable integer
    range declarations, and exact rejection of root `len`, root `range`, and
    two-variable integer ranges;
  - renders a logical range over a running container's nonempty publisher
    collection, then creates a one-off container with no publishers and
    rejects the same template after it selects the root formatter row;
  - verifies JSON normalization preserves the valid `a` in a byte prefix and
    escapes only its invalid partial UTF-8 suffix;
  - verifies CRLF-separated field actions, control actions, and trim markers;
  - rejects non-breaking spaces as action and control separators exactly as Go
    does while retaining literal non-ASCII whitespace outside actions;
  - verifies `.Labels` through generic string helpers, rejects root `index`
    and the unsupported `table` template function, and compares direct and
    `%s` partial UTF-8 output byte-for-byte.

## Validation

The final local verification passed on the MacBook Pro:

```sh
make swift-coverage
make go-test
make coverage-check
make check
swiftlint lint --strict --quiet \
  Sources/ComposeCore/ComposeDockerTemplateData.swift \
  Sources/ComposeCore/ComposeStructuredFormatTemplate.swift \
  Sources/ComposeCore/ComposeStructuredTemplateAnalysis.swift \
  Sources/ComposeCore/ComposeStructuredTemplateEvaluation.swift \
  Tests/ComposeCoreTests/ComposeDockerTemplateJSONTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateCompatibilityTests.swift \
  Tests/ComposeCoreTests/ComposeStructuredFormatTemplateTests.swift
swiftformat --lint --swift-version 6.2 \
  Sources/ComposeCore/ComposeDockerTemplateData.swift \
  Sources/ComposeCore/ComposeStructuredFormatTemplate.swift \
  Sources/ComposeCore/ComposeStructuredTemplateAnalysis.swift \
  Sources/ComposeCore/ComposeStructuredTemplateEvaluation.swift \
  Tests/ComposeCoreTests/ComposeDockerTemplateJSONTests.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateCompatibilityTests.swift \
  Tests/ComposeCoreTests/ComposeStructuredFormatTemplateTests.swift
shellcheck Tools/parity/check-compose-format-template-actions.sh
CONTAINER_COMPOSE_CONTAINER=/opt/homebrew/opt/container-current/bin/container \
  make docker-compose-format-template-actions-parity
git diff --check
```

- Swift: 1,179 tests in 34 suites passed.
- Swift repository coverage: 91.99%.
- Go normalizer coverage: 89.88%.
- Structured template engine and support: 2,155/2,263 lines, 95.23%.
- `ComposeStructuredFormatTemplate.swift`: 654/683 lines, 95.75%.
- `ComposeStructuredTemplateAnalysis.swift`: 504/517 lines, 97.49%.
- `ComposeStructuredTemplateCompatibilitySyntax.swift`: 60/64 lines,
  93.75%.
- `ComposeStructuredTemplateEvaluation.swift`: 157/170 lines, 92.35%.
- `ComposeStructuredTemplateLookup.swift`: 29/35 lines, 82.86%.
- `ComposeStructuredTemplateWhitespace.swift`: 32/32 lines, 100%.
- `ComposeDockerTemplateData.swift`: 160/170 lines, 94.12%.
- `ComposeDockerTemplatePrintSupport.swift`: 52/56 lines, 92.86%.
- `ComposeDockerTemplatePrintf.swift`: 292/304 lines, 96.05%.
- `ComposeDockerTemplateFunctionSupport.swift`: 158/175 lines, 90.29%.
- `ComposeDockerTemplateStringSupport.swift`: 57/57 lines, 100%.
- Formatter table boundary: 177/178 lines, 99.44%.
- Command rendering helpers: 539/577 lines, 93.41%.
- Repository checks passed, including 167 release-controller tests, 14
  CI-helper tests, stack consistency, release consistency, licence validation,
  and credential scanning.
- The focused formatter SwiftLint and SwiftFormat gates passed; the repository
  `make check` gate covered the legacy orchestrator test file with its checked-in
  lint configuration.
- The committed integration fixture passed against Docker Compose 5.3.1 and
  the Apple Current stack:
  - `container` `c65687b084b08cf4ca5fe0d7d9b5225e1843d55f`;
  - `containerization`
    `164088e02e16ed80e536d0c59822b09931d213df`;
  - `container-compose` base
    `b644c71fd0f7dd665a2a74192ab55745faafa281`.
- SonarQube pull-request analysis for implementation commit
  `0390a85d2952bd82e50fb98219c9207a39664377` passed with zero unresolved
  issues, 92.0% new-code coverage, 0.0% new duplication, A ratings for
  reliability, security, and maintainability, and 100% hotspot review.

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
identified fifty-one actionable compatibility cases and three suggestions that
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
- Go's `else with` shorthand is parsed as a nested `with` continuation, while
  invalid `else if` after `with` and `else with` after `if` or `range` remain
  rejected.
- `.Label` and root-scoped `$.Label` accept their key from the preceding
  pipeline value, retain dynamic table-key analysis, compose with later
  helpers, and reject an additional explicit argument.
- statically known label keys remain available to dynamic table-header
  rendering after single-value `print` and exact `printf` pipeline stages.
- constant string functions propagate the computed label lookup key while
  preserving Docker's source-literal table header, including `upper`, `lower`,
  `title`, `pad`, and `truncate`.
- logical root analysis now retains root status only when every reachable
  truthy result is root, so a publisher selected before a piped root remains
  publisher-scoped;
- empty-separator `split` emits one element per Go UTF-8 sequence and emits no
  elements for an empty input;
- `truncate` prefixes UTF-8 bytes and retains partial invalid strings for exact
  Go quoting.
- `.Labels` uses its rendered display as the Go string accepted by generic
  string, formatting, length, index, and slice helpers.
- static `index` access to the root formatter row is rejected during preflight
  rather than bypassing unsupported-field validation.
- direct, `%s`, `%v`, `print`, table, and command output retain partial UTF-8
  as exact bytes instead of inserting replacement characters.
- trim markers remove only Go's four ASCII whitespace characters and preserve
  adjacent non-breaking spaces and other literal Unicode whitespace.
- range expressions whose only reachable truthy result is the root formatter
  row are rejected before discovery, while mixed logical expressions are
  evaluated per row and rejected only if they actually select the root;
- CRLF is accepted between action and control tokens and around trim markers
  even though Swift represents the pair as one `Character`.
- byte-string JSON normalization preserves valid surrounding UTF-8 and emits
  `\ufffd` only for an invalid subsequence.

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
Commit `53a3bcf7253bc0ac30550731f92c8437a1c31c56` adds control-specific
continuation parsing, covers successful, chained, compact, and invalid
shorthand forms, and extends the committed live oracle across all three
formatter command paths.
Commit `e6560365bc13e61a4d861a138fb5a8a753f7693f` treats root and dot
label methods as typed pipeline functions, isolates their lookup policy,
covers rendering and field/header analysis, and extends the committed live
oracle with successful chained calls and invalid extra-argument rejection.
Commit `2c7b92c9677ec720f569156b4c111ecb595806d1` carries statically known
string keys through compatible `print` and `printf` stages, covers dynamic
table-header rendering, and extends the committed Docker Compose 5.3.1 and
Apple Current live oracle with the reported pipeline.
Commit `fe952873826f3b2b896eb61bae4c52ba77b33e6a` reuses the typed
runtime helper evaluator for constant label-key analysis, carries separate
computed lookup and source-literal header keys, and covers nested, invalid,
and control-flow expressions. The committed live oracle confirms Docker's
source-header spellings (`foo`, `FOO`, `foo`, `foo`, and `foo extra`) while
the transformed keys select the expected label values.
Commit `6f5ab6aba03ba66eee8625db178af6e95eb16f8e` tracks ordered logical
root outcomes and aligns empty-separator splitting and truncation with Go's
UTF-8 behavior. Focused analysis, rendering, and command-path coverage plus the
committed Docker Compose 5.3.1 and Apple Current oracle protect all three
reported cases.

After the connector findings were closed, an adjacent Docker Compose 5.3.1
oracle audit reproduced two further edge cases: negative `truncate` lengths
must fail, and `split` followed by `join` must preserve an invalid UTF-8 prefix
created by byte truncation. Commit
`130ed4d91b2e3402e702d6d3ba3a265d92d8dd2b` isolates raw Go string handling,
rejects negative lengths, preserves byte strings across all three helpers, and
adds focused and committed live-parity regressions.

A delayed connector review then identified `.Labels` generic helper
compatibility, root indexing, an invented `table` identity helper, and raw
output replacement. Signed commit
`fce7edbadf8acfc4bf7b410d2f116d4e5f5ca0fa` treats `.Labels` as its rendered
Go string for generic helpers, rejects root indexing before discovery, removes
the non-Docker `table` helper, and carries exact bytes through the evaluator,
table renderer, command layer, and optional stats SPI. Focused unit,
command-path, coverage, SonarQube, and live Docker Compose 5.3.1/Apple Current
evidence covers all four findings.

Two previously missed connector threads were then reconciled explicitly.
The raw-output thread duplicated the exact-byte finding and received the same
signed implementation disposition. Signed commit
`4fbd1b26023c873cc006c69a8de42e6c10979d1d` closes the remaining actionable
thread by limiting trim markers and adjacent trimming to Go's ASCII whitespace
set. Focused left/right non-breaking-space tests and the committed Docker
Compose 5.3.1/Apple Current oracle cover both directions. The oracle also
checks map-backed `.Labels` byte indexing with an order-independent unsigned
byte invariant, avoiding Docker's nondeterministic label iteration.

A fresh connector review then identified that the formatter root still behaved
like its internal object representation and that current Go templates support
integer range sequences. Docker Compose 5.3.1 rejects `{{len $}}` and
`{{range $}}{{.}}{{end}}`, emits `012` for `{{range 3}}`, takes the `else`
branch for zero and negative integers, accepts one declaration, and rejects two
declarations. Signed commit
`3fe67c044ead24cca8e7c0ee2dd2afb125772a6c` preserves those exact struct-root
and integer-range semantics before runtime discovery, with focused evaluator
and command-path tests plus the committed Docker Compose 5.3.1/Apple Current
oracle.

The same review batch contained a further connector thread that was reconciled
before merge. Docker Compose 5.3.1 rejects non-breaking spaces at action and
control boundaries with `U+00A0` parse errors, while allowing the character
inside quoted string values. Signed commit
`555dfb0ec739bb2a745d02af000d3b3ddf1f5344` applies Go's four-character
whitespace set consistently to action trimming, token and control separation,
pipelines, and range declarations. Focused evaluator and pre-discovery command
tests plus the committed Docker Compose 5.3.1/Apple Current oracle protect both
reported rejection forms.

A subsequent connector thread showed that range validation considered only
expressions whose every truthy result was the root. A one-off Docker Compose
5.3.1 container has no publishers, so
`{{range or .Publishers $}}{{.}}{{end}}` falls back to the root struct and
fails with `range can't iterate over`. Signed commit
`e63293cce41444f4e44e6aa6f2bf1ad8d099690b` added conservative possible-root
range rejection before discovery. Focused evaluator and command-path coverage
plus the one-off Docker Compose 5.3.1/Apple Current live oracle protect the
reported fallback.

A delayed connector thread showed that Swift groups CRLF into one grapheme,
while Go consumes the carriage return and line feed as two valid action
whitespace runes. Signed commit
`65c03e127348fd3246d6f90f92428cb9583d2727` recognizes that combined
`Character` without broadening the accepted Go whitespace set. Focused field,
control, and trim-marker tests plus the committed Docker Compose 5.3.1/Apple
Current live oracle protect the reported forms.

The fresh exact-head connector review then found that the conservative
possible-root check over-rejected rows whose nonempty publisher collection won
before the root fallback. Signed commit
`004ed0a65e53d90b06861c67e30cdaff5f05dcb7` moves root identity into a
dedicated evaluator result, preserves it through logical and parenthesized
expressions and `with`, and rejects `range` only when evaluation actually
selects the root. The committed Docker Compose 5.3.1/Apple Current oracle now
requires the published-port row to render successfully and the no-publisher
one-off row to fail.

The same review found that all-or-nothing UTF-8 conversion discarded valid
bytes before an invalid partial suffix during JSON normalization. Signed
commit `0390a85d2952bd82e50fb98219c9207a39664377` decodes byte strings
incrementally, retains valid scalars, emits Docker's `\ufffd` JSON escape only
for invalid subsequences, and keeps an already-valid replacement scalar
literal. Focused unit coverage and the committed live oracle protect both
forms.

The suggestion to reject `join` for publisher records was not implemented:
Docker Compose 5.3.1 accepts `{{join .Publishers ","}}` and renders
`{127.0.0.1 8080 32768 tcp}`. The same successful behavior is now protected by
unit and committed live-parity coverage. The suggestion to invent headers for
`ExitCode`, `Health`, `LocalVolumes`, `Mounts`, `Names`, `Networks`, and
`Publishers` was also not implemented: Docker Compose 5.3.1 emits
`<no value>` for every one of those table headers. Focused unit coverage and
the committed Docker/Apple live oracle now preserve that exact behavior. No
actionable autobot finding was deferred. The suggestion to propagate root
identity through `table` was not implemented because Docker Compose 5.3.1
rejects the template at parse time with `function "table" not defined`; the
unsupported helper was removed and that exact rejection is protected instead.
All fifty-five connector threads are answered with their implementation or
verified compatibility disposition.

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
- [x] SonarQube reports zero issues and passes its new-code quality gate.
- [x] README VHS source uses typed commands and live output only.
- [ ] Hosted CI, CodeQL, and quality checks pass for the exact revision.
- [ ] Current prerelease artifacts, checksums, attestations, and live VHS pass.
- [ ] Slack END records the delivered revision and promotion evidence.
