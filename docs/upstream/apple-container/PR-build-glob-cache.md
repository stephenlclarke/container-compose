# Pull Request: cache compiled build glob patterns

## Summary

- Cache translated Foundation regular expressions by their original Docker
  ignore pattern for the lifetime of one `Globber`.
- Use the cached expression directly for whole-string matching.
- Preserve the existing Swift Regex validation, Foundation matching semantics,
  pattern translation, and thrown-error behavior.

## Intended Review Delta

Apply signed commit `abab498f01c4f7325c7b41ec8254a186640824f2`
(`perf(build): cache compiled glob patterns`) from
`stephenlclarke/container`, followed by review correction
`4436afea7c31a6a6a99e37ea7254465d333d9147`
(`fix(build): preserve cached glob semantics`).

The companion report is
[ISSUE-build-glob-cache.md](ISSUE-build-glob-cache.md), and the originating
upstream report is
[apple/container#2022](https://github.com/apple/container/issues/2022).

## Code Map

- `Sources/ContainerBuild/Globber.swift`: retains Swift Regex validation,
  owns a pattern-to-`NSRegularExpression` cache, and reuses the Foundation
  expression for matching.
- `Tests/ContainerBuildTests/GlobberTests.swift`: verifies reuse across
  multiple inputs, independence between distinct source patterns, and the
  composed-versus-decomposed Unicode behavior.

## Validation

```console
swift test --disable-automatic-resolution --filter TestGlobber
make coverage-unit
make check
CONTAINER_STACK_REPO=/absolute/path/to/container \
  CONTAINERIZATION_INIT_SOURCE_PATH=/absolute/path/to/containerization \
  make docker-compose-parity
```

The focused `TestGlobber` suite passes all six test groups, including every
existing parameterized matching and invalid-pattern case plus the cache-reuse
and decomposed-Unicode regressions. Complete coverage and Compose v2 parity are
required before publication.

## Compatibility and Risks

- Cache keys are the original patterns, so patterns with different spellings
  do not accidentally share a translated expression.
- Swift Regex still validates each translated pattern once, and the cached
  Foundation expression retains the previous Unicode-scalar match behavior;
  invalid patterns still throw.
- The cache lifetime is one build-context globber and adds no global mutable
  state.
- No public API, Linux guest behavior, Windows path, or Compose-specific
  primitive changes.

## Handoff Status

No Apple remote has been pushed. The commit is deliberately independent of the
other performance findings in `apple/container#2022`.
