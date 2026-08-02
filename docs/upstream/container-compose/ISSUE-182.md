# [Request]: Require exact-head review for every Compose source promotion

## Feature or enhancement request details

Initial Workflow Enablers 13 and 14 close the last known source-promotion bypass in the stack release helper. At base `243b4f4ebe305e69a430a293c02c6e4bfaace577`, `scripts/CONTAINER_STACK_RELEASE.sh` opens a Compose promotion pull request and first attempts `gh pr merge --auto` before checks or any exact-head Codex decision. It also accepts `CONTAINER_STACK_RELEASE_COMPOSE_MAIN_PROMOTION_MODE=direct` and can push local `main` directly.

Replace both behaviours with one fail-closed protocol. The helper must bind the open pull request to the full locally gated commit, inspect all Codex review threads, require every earlier query to have a later response from Stephen and a resolved thread, post the literal `@codex review`, and wait for a clean connector decision on that request. A connector thumbs-up on the exact request or an explicit no-major-issues comment naming the expected commit prefix is clean evidence. Any new query, changed head, malformed or truncated response, stale clean comment, or timeout must stop promotion and surface the reason. After a query is answered and resolved—or after any diff change—the next invocation must post a fresh request.

Only after a clean decision may pull-request checks run. Immediately before merge, revalidate the open head, every query, and the clean signal. Merge with `--match-head-commit`; never enable auto-merge. The optional checked-admin path may address only GitHub's solo-maintainer review requirement and must repeat the same review and check gates. Remove the direct push branch and reject the legacy `direct` value before mutation.

## Compose compatibility impact

Release workflow only. This changes no Compose parsing, runtime operation, package payload, stack pin, Docker oracle, or performance threshold. It prevents unreviewed source from reaching `main`, signed tags, Current/stable packages, or the Homebrew tap.

## Acceptance criteria

- [x] The helper accepts only `CONTAINER_STACK_RELEASE_COMPOSE_MAIN_PROMOTION_MODE=pr`; `direct` exits before GitHub or Git mutation.
- [x] The promotion PR must remain open at the full locally gated head before and after the literal `@codex review` request.
- [x] Every Codex review query has a later `stephenlclarke` response and a resolved thread before another request or clean decision is accepted.
- [x] A query created at or after the current request invalidates that request and requires a fresh invocation.
- [x] GraphQL thread pagination is complete; truncated top-level or nested comment evidence fails closed.
- [x] Clean authority is limited to a connector thumbs-up on the exact request or an explicit connector no-major-issues comment naming the expected head prefix.
- [x] A stale head, stale clean comment, malformed response, or review timeout cannot reach checks or merge.
- [x] Pull-request checks run only after clean review, and review/head/query evidence is immediately revalidated afterwards.
- [x] Normal and checked-admin merges use `--match-head-commit`; checked-admin repeats checks and review validation.
- [x] The helper never enables `--auto` and contains no Compose direct-main push branch.
- [x] Deterministic evaluator and release-helper tests cover stale head, unanswered query, post-request query, timeout, clean-comment merge, stale clean comment, pagination, and direct-mode rejection.
- [x] BUILD and the normative development cycle describe the delivered fail-closed protocol.
- [x] Exact final-head local gates, CodeQL, Sonar, hosted checks, signed Current publication, and clean review are recorded in `PR-182.md`.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked existing issue records before preparing this request.
