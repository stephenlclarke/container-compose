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

Both implementation commits are signed and construct the complete code delta.
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
  - retains the public row-rendering boundary and delegates to the structured
    engine.
- `Sources/ComposeCore/ComposeRenderHelpers.swift`
  - projects structured publishers, labels, mounts, networks, local-volume
    counts, and volume labels for the owning command rows.
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
- `Tests/ComposeCoreTests/ComposeOrchestratorTests.swift` and
  `Tests/ComposePluginTests/ComposeCLIHelpTests.swift`
  - cover structured command rows and honest support metadata.
- `Tools/parity/fixtures/output-template/compose.yaml` and
  `Tools/parity/check-compose-format-template-actions.sh`
  - provide the committed Docker Compose v2 oracle for container publishers,
    labels, stats control flow, volume labels, functions, and whitespace.

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
  Sources/ComposeCore/ComposeRenderHelpers.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateTests.swift
swiftformat \
  Sources/ComposeCore/ComposeFormatTemplate.swift \
  Sources/ComposeCore/ComposeDockerTemplateData.swift \
  Sources/ComposeCore/ComposeDockerTemplateFunctionSupport.swift \
  Sources/ComposeCore/ComposeDockerTemplatePrintf.swift \
  Sources/ComposeCore/ComposeStructuredFormatTemplate.swift \
  Sources/ComposeCore/ComposeRenderHelpers.swift \
  Tests/ComposeCoreTests/ComposeFormatTemplateTests.swift \
  --lint --swift-version 6.2
CONTAINER_COMPOSE_CONTAINER=/opt/homebrew/opt/container-current/bin/container \
CONTAINER_COMPOSE="$PWD/.build/debug/compose" \
DOCKER_COMPOSE_REFERENCE='docker compose' \
CONTAINER_COMPOSE_LIVE=1 \
  make docker-compose-format-template-actions-parity
git diff --check
```

- Swift: 1,134 tests in 27 suites passed.
- New structured formatter: 1,003/1,086 lines, 92.4%.
- `ComposeStructuredFormatTemplate.swift`: 773/841 lines, 91.9%.
- `ComposeStructuredTemplateWhitespace.swift`: 18/18 lines, 100%.
- `ComposeDockerTemplateData.swift`: 81/85 lines, 95.3%.
- `ComposeDockerTemplatePrintf.swift`: 73/75 lines, 97.3%.
- `ComposeDockerTemplateFunctionSupport.swift`: 58/67 lines, 86.6%.
- Existing formatter boundary: 39/41 lines, 95.1%.
- Command rendering helpers: 765/796 lines, 96.1%.
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
identified five actionable compatibility cases:

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

Commit `af1e012fb4fad4162a1841bd9a13f80be68d9fb4` fixes all three and adds focused
template regressions. Commit `0fa6bafd119829df09da2b1555a5c463f1d41fc9`
fixes both runtime mount projections with command-path regression coverage. No
autobot finding was deferred.

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
