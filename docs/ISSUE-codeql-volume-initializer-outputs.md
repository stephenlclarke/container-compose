# Local Go CodeQL rejects its volume initializer build outputs

## Problem

The maintained Go build now produces the host normalizer and two Linux volume initializers. The local CodeQL exact-source check still expects only the normalizer, so a completed analysis fails when it finds the two additional binaries in its private checkout.

## Expected behavior

Admit exactly the three production build outputs. Continue rejecting tracked source changes and unexpected untracked files. Keep the private checkout, pinned tools and SARIF validation unchanged.

## Compatibility impact

Local security workflow only; product source and the semantic fixture inventory do not change. See [implementation and validation](PR-codeql-volume-initializer-outputs.md).
