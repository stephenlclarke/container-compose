# Issue 351: fail fast release inputs and skip unchanged DocC APIs

## Problem

The 0.14.0 release exposed avoidable critical-path work and late failure points. Homebrew token, tap, formula, and source-template defects are knowable before native builds, but the hosted and local release paths reached some of those checks only after expensive work. CodeQL was release authority yet ordinary development and benchmark documentation could dispatch it. The documentation workflow rebuilt four DocC sites even when a Swift change provably left documented API unchanged. Stable package publication could also trigger the mutable Current demo.

Tracking issue: [`#351`](https://github.com/stephenlclarke/container-compose/issues/351).

## Required outcome

- Validate the writable tap token, tap identity and cleanliness, stable/current formula pairing, Ruby syntax, immutable URLs and SHA fields, and both pinned source formulae before CodeQL or product builds.
- Run repository governance and static source checks before slower policy-test harnesses.
- Run hosted CodeQL only for Current or stable publication, with a manual recovery lane restricted to an already published release.
- Skip DocC for benchmark-only, unrelated, and proven implementation-only changes; rebuild for documented API/site inputs and every ambiguous source classification.
- Fail fast across the DocC matrix.
- Do not run Current demo recording for stable package runs.
- Preserve only the lightweight `Validate` check as an ordinary protected-branch authority.

## Acceptance evidence

- Focused classifier and preflight regressions cover public static declarations, implicit protocol requirements, macro ambiguity, lane pairing, dirty taps, and stable-version policy.
- The complete release-policy test file, Actionlint, Bash syntax, ShellCheck, Markdownlint, Ruby syntax, the real tap preflight, and an exact-head review pass.
- The implementation lands through a signed Conventional Commit and protected pull request.
