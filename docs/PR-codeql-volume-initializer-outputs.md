# fix(ci): admit production volume initializer CodeQL outputs

## Problem and behavior

The local Go CodeQL scan completes extraction and analysis but rejects the ARM64 and AMD64 volume initializer binaries produced by its own maintained build. The exact-source check now admits the complete, explicit three-file production output set.

## Validation

The existing independent-checkout regression reproduces the failure when both initializer files are present. The updated regression accepts those outputs, rejects an unexpected fourth output, and continues rejecting tracked source mutation. Run the complete local CodeQL tool test module and the maintained real Go scan on the clean commit.

## Compatibility and risks

No wildcard admission, ignored-source allowance, product change or historical baseline execution is added. Source isolation, pinned tools, raw object checks and SARIF validation remain enforced. Related: [the issue](ISSUE-codeql-volume-initializer-outputs.md) and [PR 708](https://github.com/stephenlclarke/container-compose/pull/708).
