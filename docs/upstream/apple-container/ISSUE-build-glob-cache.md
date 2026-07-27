# Performance: build glob patterns are compiled for every candidate path

## Summary

`Globber.glob` converts a Docker ignore pattern into a regular expression and
compiles that expression every time a candidate path is tested. A build context
with many paths and patterns therefore repeats identical compilation work in
the inner matching loop.

This reproduces the first performance finding in
[apple/container#2022](https://github.com/apple/container/issues/2022).

## Reproduction on macOS

1. Create a build context containing many files and a `.dockerignore` with
   several glob patterns.
2. Run `container build`.
3. Profile `Globber.glob`; the same translated expression is compiled for each
   candidate tested against the pattern.

## Expected behavior

Each `Globber` instance should compile a source pattern at most once and reuse
the same Foundation regular expression for subsequent whole-string matches,
while retaining the existing Swift Regex validation.

## Ownership and boundary

This is generic build-context filtering in `apple/container`. The correction
belongs in `Globber`; neither Compose nor the builder shim should maintain a
parallel pattern cache.

## Commit tracking

- `abab498f01c4f7325c7b41ec8254a186640824f2` —
  `perf(build): cache compiled glob patterns`.
- `4436afea7c31a6a6a99e37ea7254465d333d9147` —
  `fix(build): preserve cached glob semantics`.

## Validation expectations

- Preserve all existing Docker ignore matching cases, including invalid
  patterns.
- Preserve Foundation's composed and decomposed Unicode matching behavior.
- Prove that repeated matches for one source pattern leave one cached compiled
  expression.
- Run the complete Container unit and coverage gates.
- Retain Docker Compose v2 build-context parity.
