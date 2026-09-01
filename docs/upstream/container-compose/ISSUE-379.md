# Issue 379: skip packaging immediately for documentation-only CI

## Problem

The first completed historical benchmark report merged as a documentation-only change. Its exact pull-request head passed the documentation validation path, but the successful main CI still triggered Prebuilt Binaries. The packaging resolver then entered the exact-main SonarQube polling path even though CI had intentionally skipped `Validate Runtime`, so no product input had changed and no SonarQube scan could exist for that commit.

Tracking issue: [`#379`](https://github.com/stephenlclarke/container-compose/issues/379).

## Required outcome

- Treat an intentionally skipped `Validate Runtime` job as authoritative documentation-only classification.
- Exit the package resolver immediately without SonarQube polling, package work, or downstream publication.
- Preserve existing fail-closed behavior for missing, unsettled, failed, or unreadable CI authority.
- Preserve normal packaging for exact-main CI whose `Validate Runtime` job succeeds.

## Acceptance evidence

- Focused workflow contract tests cover the runtime-classification guard and its position before SonarQube polling.
- Actionlint and `git diff --check` pass.
- The repository setting permits GitHub Actions to create the benchmark's documentation pull request.
- Exact-head review finds no further issue.
