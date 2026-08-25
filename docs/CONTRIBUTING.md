# Contributing To container-compose

Thank you for helping improve `container-compose`. This project aims to stay
small, readable, and aligned with the design style of
[`apple/container`](https://github.com/apple/container), so changes should be
focused and easy to review.

The contributor workflow intentionally follows the applicable parts of
[`apple/container`](https://github.com/apple/container/blob/main/CONTRIBUTING.md)
and its delegated
[`apple/containerization` contributing guide](https://github.com/apple/containerization/blob/main/CONTRIBUTING.md).
That keeps this repository easier to compare, review, and potentially offer
upstream with minimal reshaping.

## Pull Requests

Use pull requests for all human-authored changes. The sole automation exception
is the deterministic `container` package-pin commit published by the
release helper under the allowlist, fast-forward, local-check, and assembled-stack
gates in [BUILD.md](guides/BUILD.md); it is not a feature-delivery or checkpoint path.

1. Fork the repository or create a topic branch from `main`.
2. Keep each pull request focused on one bug fix, feature, or documentation
   update.
3. Sign every commit with a GitHub-supported signature method such as SSH or
   GPG.
4. Discuss substantial features or design changes in an issue before writing a
   large patch.
5. Add or update tests for behavior changes.
6. Update documentation when behavior, commands, installation, or developer
   workflow changes.
7. Update [STATUS.md](project/STATUS.md) when current runtime support changes. Update
   [BACKLOG.md](project/BACKLOG.md) and the linked GitHub issue when planned parity
   work changes.
8. Run the validation described in [BUILD.md](guides/BUILD.md) before requesting
   review.

Keep a pull request in draft while active or iterative development is in
progress. The active `CodeQL` workflow defers draft pull requests, analyzes
ready pull requests when their changes can affect the Go normalizer or CodeQL
configuration, and publishes an explicit no-op gate for unrelated ready pull
requests. Every `main` push, scheduled run, and manual dispatch performs the
actual Go analysis. Branch protection requires the aggregate `CodeQL` check;
a missing or unsuccessful check is not a passing result.

Source `Tools/ci/codeql-entry.sh` from a Bash or Zsh process containing neither the `GITHUB_TOKEN` nor `GH_TOKEN` shell variable, then use `container_compose_codeql codeql-local` for the supported exact-build Go analysis as a reproducible local complement to the hosted workflow; raw invocation of `codeql-make.py` or its underlying Make goal is not a supported security boundary. A shell can expand an inherited xtrace prompt before any function body starts, so the supported caller has tracing disabled and contains no credential variable. The entry records and disables incoming tracing, then rejects an already-traced or credential-bearing caller before it starts Python or reads the keyring. Authenticate `gh` into its keyring before starting the credential-free shell; a real upload obtains that credential through the privately extracted pinned GitHub CLI only after the boundary has disabled tracing and functions and removed the inherited environment. Before resolving any caller-shadowable command, the sourced entry removes every enabled shell function in its subshell, disables tracing, uses explicit shell builtins to unexport the complete inherited environment, re-exports only reviewed goal-specific data, and directly execs isolated absolute Python before the Python launcher starts an explicit absolute Makefile. Native-loader controls and inherited command functions cannot execute through an intermediate helper, and the post-scrub GitHub credential never appears in an argument. The inner recipe and script shebang use isolated reviewed `/usr/bin/python3`; unrelated discovery is lazy and uses absolute system Git, configurable roots/upload identity cross into Python as literal exported values rather than shell-interpolated source, and every Git command ignores global/system configuration and replacement objects while overriding executable local settings such as `core.fsmonitor`. Worktree verification bypasses Git conversion filters by comparing HEAD, index, and raw blob bytes directly, so local filter commands and `.git/info/attributes` do not execute. It caches only reviewed archive bytes, copies and authenticates each selected archive inside a randomized private directory, and keeps the privately extracted CodeQL and official Go tools through the operation. It builds from a temporary detached exact-commit clone through recorded absolute Git, archive, download, GNU Make, and Go tools with a fixed system `PATH` and controlled environment, uses fresh temporary Go module/build caches with checksum-database verification and no VCS fallback, retains commit-keyed SARIF, and fails results without a current reviewed baseline disposition. An authorised maintainer can pass an explicit full remote ref and commit in the environment to the function's `codeql-sarif-upload-dry-run` and then `codeql-sarif-upload` goals. A real upload regenerates the analysis with the verified bundle and authenticates its retained projection against in-memory digests; ignored SARIF and manifest files alone never authorize upload. It binds confirmation to GitHub's unique validated SARIF receipt and matching `sarif_id` analysis, so another same-commit upload cannot satisfy the gate. Credential lookup and authenticated API reads use only the operation-private, archive-pinned official GitHub CLI `2.96.0`, which remains available through receipt confirmation; package-manager paths, caller wrappers, environment tokens, and custom CLI overrides are unsupported. Before token selection, the canonical remote-ref lookup, GitHub CLI keyring read, credential-bearing CodeQL call, and receipt queries all discard caller proxy variables and custom certificate roots and use direct system trust; a network that requires an unreviewed interception proxy therefore fails closed. The uploader records the remote-identity and credential policies separately, does not call the Checks API, and does not dispatch or impersonate the hosted workflow. GitHub can attach an automatic neutral `CodeQL` service record to uploaded SARIF; neutral is not passed and must not be represented as a hosted-workflow result. See [BUILD.md](guides/BUILD.md#codeql-analysis) for pins, credentials, evidence paths, and commands.

The supported caller is trap-free and has Bash `functrace`/`errtrace` plus shell xtrace disabled. The entry clears inherited Bash `DEBUG`, `RETURN`, and `ERR` handlers, disables their inheritance modes, and rejects their recorded flags before starting any executable. It captures and atomically disables Zsh `TRAP*` functions with the enabled-function table, then rejects that caller too. A shell trap that can run before the function body is unsupported ambient code, not an input the credential boundary can safely sanitize.

Caller `TMPDIR`, `TMP`, and `TEMP` are not reviewed inputs and never cross the supported boundary. Private analysis, verified-tool, credential-tool, and SARIF-snapshot directories use a fixed root-owned temporary parent that must be non-writable by other principals or protected by the sticky bit; only the explicitly untrusted retained evidence projection is copied to the configured artifact root and immediately re-authenticated.

Maintainers review pull requests before merge. Direct pushes to protected
branches should be limited to maintainers and automation that has passed the
required checks.

Use the issue templates when reporting bugs, requesting features, or tracking a
Compose compatibility gap. Use [SUPPORT.md](SUPPORT.md) for usage questions,
security routing, and deciding whether a report belongs in an issue or a
discussion.

## Maintainer Development Cycle

The [Container-family parity development cycle](architecture/container-family-development-cycle.md) is the detailed cross-repository process for oracle-first vertical slices, one coherent critical-path implementation stream, focused feedback during development, one immutable full-gate checkpoint, full review convergence, self-hosted MBP jobs, main checkpoints, quality analysis, upstream surveillance, and transactional cleanup. This document remains authoritative for general contribution, commit, pull-request, and worktree rules.

When a parity slice changes released support, update [STATUS.md](project/STATUS.md) in
the same change. Keep current functionality readable and move future work to
[BACKLOG.md](project/BACKLOG.md) and the GitHub issue hierarchy. Put exact accepted
heads and detailed validation in the affected design or handoff record; do not
duplicate live issue state in another progress register.

For stephenlclarke-owned stack work, keep `main` as the current integration
branch in `container-builder-shim`, `containerization`, `container`,
`container-compose`, and `homebrew-tap` after each reviewed slice lands. Use a
short-lived topic or review branch for runtime, release, security,
upstream-import, and cross-repository stack changes so CI, review notes, and
upstream provenance stay attached to a stable diff before the result lands on
`main`.

Most contributions do not run release automation. Maintainers use the single
current procedure in [BUILD.md](guides/BUILD.md) after a validated slice lands on
`main`.

For a local Apple-shaped handoff, keep the proposed change title and body clear enough to stand alone as a final change description. Use imperative wording, describe what changed, and include the reason. The parity programme does not submit, refresh, or comment on Apple issues, discussions, branches, or pull requests.

### Topic Worktree Close-Out

Use one named topic branch only when it has an active pull request or a recorded
review purpose. Create exploratory and validation-only worktrees detached from
the target commit so they cannot leave a branch behind.

Before creating a topic branch, and again when a pull request reaches a terminal
state, run:

```sh
git fetch --all --prune --no-tags
make worktree-audit
```

After a pull request is merged or deliberately superseded, remove its clean
worktree and local branch in the same close-out step, then prune stale worktree
metadata:

```sh
git worktree remove /path/to/topic-worktree
git branch -d topic-branch || git branch -D topic-branch
git worktree prune
```

Do not delete a branch merely because its remote was removed: squash merges and
closed pull requests can leave unique local commits. `make worktree-audit`
separates active remote branches, safe integrated cleanup candidates, and local
branches that need a pull request or an explicit retention decision. Run the
ordinary audit again after close-out and resolve only slice-owned candidates;
report and preserve unrelated candidates. Reserve `make worktree-audit-strict`
for a coordinated repository-wide maintenance pass after every reported
candidate has been accounted for. The forced fallback is only appropriate after
the pull request is confirmed merged or deliberately superseded and the audit
shows no unique patches.

## Conventional Commits

Use Conventional Commits for commit messages and pull request titles:

```text
type(scope): short imperative summary
```

Common types include:

- `feat` for a user-facing feature.
- `fix` for a bug fix.
- `docs` for documentation-only changes.
- `test` for test-only changes.
- `refactor` for behavior-preserving code cleanup.
- `ci` for workflow or automation changes.
- `chore` for maintenance that does not affect runtime behavior.

Examples:

```text
feat(up): recreate services when config changes
fix(ps): filter containers by compose project label
docs(install): clarify plugin archive layout
```

GitHub release notes promote user-facing highlights from commit trailers.
When a commit adds or fixes a Docker Compose feature, CLI option, or visible
workflow behavior, add a single-line `Release-Note:` trailer written for users:

```text
feat(build): support build SSH forwarding

Release-Note: Supports Docker Compose build SSH forwarding from `--ssh` and `build.ssh`.
```

Use `Release-Note: none` for a feature-shaped internal change that should stay
out of release highlights. The raw commit list is still included for audit
detail, so keep the Conventional Commit subject accurate even when a trailer is
present.

For upstream-driven work, add the original reference with `Upstream-Ref:`,
`Bug-Ref:`, `Refs:`, or `Follow-up-To:`. The release-note renderer appends
missing references to the highlight so users can see which Docker Compose,
Apple, or builder-shim issue or pull request shaped the change.

## Quality Bar

Every code change should be covered by tests at the right level. Prefer small
unit tests for parsing, planning, naming, and command construction. Add
integration-style tests when a change crosses the Swift orchestrator and Go
normalizer boundary.

Coverage must stay above the project threshold. New fixes should not drop
coverage below 80 percent for the affected area, and the repository gate uses
the stricter threshold documented in [BUILD.md](guides/BUILD.md).

## Upstream Adoption Friction

Keep every contribution easy for apple/container maintainers to assess:

- Prefer direct [`apple/container`](https://github.com/apple/container) APIs
  where available and keep CLI compatibility fallbacks explicit.
- Preserve the Swift orchestration and Go `compose-go` normalization boundary
  described in [DESIGN.md](project/DESIGN.md).
- Keep current limitations explicit in [STATUS.md](project/STATUS.md), planned parity
  work in [BACKLOG.md](project/BACKLOG.md), and Apple-shaped work in the relevant
  `upstream/` handoff.
- Follow the Apache License, Version 2.0, and keep license headers current with
  `make update-licenses`.
- Use `make fmt`, `make check`, and `make pre-commit` so formatting and license
  checks stay close to apple/container's Hawkeye-based workflow.
- Avoid editor-specific root `.gitignore` entries. Use a global Git ignore file
  for personal editor or machine files.
- Keep AI-assisted changes explainable. Contributors should understand and be
  able to justify every line they submit.

## Coding Guidelines

- Keep orchestration logic in Swift and Compose normalization in the Go helper.
- Prefer the existing project structure over new abstractions.
- Keep unsupported Compose features explicit and actionable.
- Keep [STATUS.md](project/STATUS.md) aligned with current functionality and
  validation. Keep [BACKLOG.md](project/BACKLOG.md) aligned with the GitHub parity
  hierarchy.
- Run `make check` for fast lint and license-header validation before larger
  test runs.
- Use deterministic names, labels, and output ordering where possible.
- Match [`apple/container`](https://github.com/apple/container) naming,
  formatting, and error-reporting conventions when the equivalent pattern
  exists.
- Keep comments useful: document public APIs and non-obvious behavior, not
  obvious assignments.

## Keeping Protected Branches Safe

Third-party contributions must not be able to break `main` or release tags.
Maintainers should keep these guardrails enabled:

- Require pull requests before merging to protected branches.
- Require passing validation and coverage checks before merge.
- Require maintainer review for external contributors.
- Restrict write access to trusted maintainers.
- Avoid running untrusted pull request code with write-scoped secrets.
- Keep pull requests focused on one accepted issue or coherent change. If a
  pull request needs several fixup commits during review, squash those fixups
  before merge when they do not carry useful review history.
- Preserve meaningful issue commits when merging a tested batch. Avoid
  combining unrelated changes just to reduce CI runs.

Do not include credentials, tokens, certificates, private keys, or personal data
in pull requests, tests, examples, logs, or screenshots.

## Code Of Conduct

Contributors are expected to follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md),
which points to Apple's community standard used by apple/container and
Containerization.

## Licensing

By contributing, you agree that your contribution is licensed under the Apache
License, Version 2.0, matching the project license.
