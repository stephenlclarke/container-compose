# Bug: label values containing `=` are rejected

## Summary

`container run --label key=value=more` rejects a valid label because the
generic label parser splits the value at more than the first separator. Nested
configuration values, URL query strings, and routing rules commonly contain
`=` and should remain intact.

## Expected behavior

The first `=` separates a non-empty label key from its value. Every remaining
`=` belongs to the value. A label without a separator retains the established
empty-value behavior.

## Ownership and boundary

This is the generic `apple/container` CLI/API parsing boundary. Compose owns
Compose-file decoding and does not need a Docker-shaped fallback. The generic
runtime receives an ordinary `[String: String]` label map after parsing.

## Upstream context

[apple/container#1977](https://github.com/apple/container/issues/1977)
documents the same macOS reproduction and expected Docker-compatible result.

## Commit tracking

- `47c13a8ad0bf001fb569a17e73e2e3b8d4e45dff` —
  `fix(labels): preserve equals in values`

## Validation expectations

- Parser coverage must preserve all text after the first `=`.
- A macOS CLI integration test must create a guest with nested label values and
  verify the persisted values through `container inspect`.
