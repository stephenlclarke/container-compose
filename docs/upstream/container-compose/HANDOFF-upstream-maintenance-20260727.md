# Cross-MBP handoff: upstream maintenance

Updated: 2026-07-27 10:40 BST

## Stop point

The source changes for this slice are merged. Exact-main validation and
documentation are still running, the `current` prerelease has not yet moved to
the merge, and the final documentation/Slack closeout has not been completed.
Do not begin the next parity slice until these publication gates are closed.

The durable goal remains:

> Complete every macOS-feasible Container Compose parity phase 1 through 6 in
> order, with Apple-shaped fork commits, unit and Docker Compose V2 parity
> coverage, current documentation, Sonar cleanup, main publication, slice
> prereleases, and `-+-` stable releases at phase boundaries.

The user waived only the soak gate.

## Workflow rules to retain

- Implement macOS-hosted functionality only. Include Linux guest behavior that
  can be exercised through the macOS runtime; skip Windows-only work.
- Prefer Compose-layer abstractions and minimally invasive, independently
  useful Apple-fork commits.
- Use signed Conventional Commits. Do not use `codex` in a branch name, commit
  subject, or pull-request title.
- Request an exact-head `@codex review` before merge. Respond directly to each
  actionable `chatgpt-codex-connector[bot]` comment and resolve its thread.
- Immediately before every merge, run the thread-aware review fetcher:

  ```sh
  review_script="/Users/sclarke/.codex/plugins/cache/"
  review_script="${review_script}openai-curated-remote/github/"
  review_script="${review_script}0.1.8-2841cf9749ae/skills/"
  review_script="${review_script}gh-address-comments/scripts/fetch_comments.py"
  GH_REPO=<owner/repo> python3 "${review_script}" <pr-number>
  ```

- Send detailed Slack START and END messages for every slice to
  `xyzzytools.slack.com#codex`, channel ID `C0B1RNM8ZJ5`.
- Immediately before each Slack send, fully reread the Slack, outgoing-message,
  and Slack Markdown skill files under the installed Slack plugin.
- The README VHS source must visibly type commands and show their real output.
  It must contain no `Replay` or `Marker` directives.
- Preserve dirty primary worktrees and use isolated worktrees.
- Push each completed slice to `main`, publish its prerelease, and run/fix
  Sonar before moving beyond a phase boundary.

## Slice notification

Slack START was already sent and must not be duplicated:

<https://xyzzytools.slack.com/archives/C0B1RNM8ZJ5/p1785127242796979>

The final slice END is still required after all gates and release verification
complete. A stop/handoff update is expected when this checkpoint is pushed.

## Runtime fork result

Repository: `stephenlclarke/container`

Temporary worktree:

`/tmp/container-upstream-2022.QpmflP/worktree`

PR:
[stephenlclarke/container#30](https://github.com/stephenlclarke/container/pull/30)

Reviewed feature head:

`281208b1a8db06c92348afdeb1c163e043637c16`

Merged runtime main:

`5796a79ee3e59c16098d086278c072740d519ee8`

The merge tree exactly matches the reviewed head. Hosted run
[30249659444](https://github.com/stephenlclarke/container/actions/runs/30249659444)
passed signatures, build, package, and project tests. All five actionable
connector threads have direct responses and are resolved. The exact-head
connector review reported no major issue.

The eleven independently useful signed implementation commits are enumerated
in
[PR-upstream-maintenance-20260727.md](PR-upstream-maintenance-20260727.md).
They cover compiled ignore globs, hashed context membership, concurrent stats,
off-lock sizing, ordered/failure-safe init bootstrap, isolated volume prune,
Unicode-sensitive glob semantics, partial-bootstrap cleanup, active-runtime
reuse, snapshot-consistent volume usage, and isolated integration bootstrap
configuration.

Runtime validation:

- 1,148 unit tests in 134 suites
- 39.27% unit line coverage
- 293 concurrent plus 87 serial source-matched integration scenarios
- 51.56% combined runtime coverage
- 62 strict Docker Compose V2 5.3.1 parity assertions

## Compose result

Repository: `stephenlclarke/container-compose`

Temporary worktree:

`/tmp/container-compose-upstream-audit.Vx0u4E/worktree`

Implementation branch:

`chore/upstream-audit-20260727`

Issue:
[stephenlclarke/container-compose#165](https://github.com/stephenlclarke/container-compose/issues/165)

PR:
[stephenlclarke/container-compose#166](https://github.com/stephenlclarke/container-compose/pull/166)

Reviewed PR head:

`eb6ac58ec3cdc90e47f6f88e346a5038691964c1`

Merged Compose main:

`4fe88b796fe2b4b3008ccc7da8d284cedd4235c4`

The merge tree exactly matches the reviewed head. The signed Compose commits
are:

- `6cae9a84deee2b13eecfeb1efbf83ad2c98f88a9` — remove oversized
  release-only dependency caches
- `e45240b718bf88a709e4fbb7056dfa0af4a1811e` — initial reviewed runtime
  pin
- `c9a343f0d658dbb576c52a33e1ea97f3130bc730` — pin merged runtime
  `5796a79ee3e59c16098d086278c072740d519ee8`
- `c28b0fe3ba3aba1c353a80d9678329c16755f79d` — refresh upstream audit and
  handoffs
- `eb6ac58ec3cdc90e47f6f88e346a5038691964c1` — link issue #165

Local exact-pin validation:

- `HAWKEYE_AUTO_INSTALL=1 make ci`: green
- 1,249 Swift tests in 41 suites
- Swift coverage 92.81%
- Go coverage 89.88%
- 175 release-policy tests
- stack consistency, formatting/lint, licenses, JSON, and archive verifier:
  green
- seven immutable upstream PR archive refs verified live
- Docker Compose V2 5.3.1 parity: 62 strict assertions
- README tape: 16 `Type`, 16 `Enter`, 14 live waits/screens, zero `Replay`,
  and zero `Marker`

PR #166 hosted evidence:

- CI
  [30251651045](https://github.com/stephenlclarke/container-compose/actions/runs/30251651045):
  green
- CodeQL
  [30251651099](https://github.com/stephenlclarke/container-compose/actions/runs/30251651099):
  green
- Quality
  [30251651067](https://github.com/stephenlclarke/container-compose/actions/runs/30251651067):
  green, including Swift ASan
- Documentation
  [30251651028](https://github.com/stephenlclarke/container-compose/actions/runs/30251651028):
  green
- immutable archive verification
  [30251651053](https://github.com/stephenlclarke/container-compose/actions/runs/30251651053):
  green
- exact-head connector review: no major issues and zero review threads

## Exact-main work in flight

All runs target exact merge
`4fe88b796fe2b4b3008ccc7da8d284cedd4235c4`.

- CI
  [30253458586](https://github.com/stephenlclarke/container-compose/actions/runs/30253458586):
  in progress in `Run coverage gate`
- CodeQL
  [30253458549](https://github.com/stephenlclarke/container-compose/actions/runs/30253458549):
  green
- Quality
  [30253458554](https://github.com/stephenlclarke/container-compose/actions/runs/30253458554):
  green
- Documentation
  [30253458571](https://github.com/stephenlclarke/container-compose/actions/runs/30253458571):
  in progress in `Build static API documentation`
- immutable archive verification
  [30253458622](https://github.com/stephenlclarke/container-compose/actions/runs/30253458622):
  green

CI must finish coverage, CLI smoke, and an exact-revision Sonar scan. Its
successful completion automatically starts the `Prebuilt Binaries` workflow.
Do not dispatch a duplicate package run while the automatic run is viable.

The `current` prerelease is still the previous publication:

- target:
  `e0e076c930e15828cd4d94f4d312a72ab8283846`
- published: 2026-07-27 04:35:15 UTC
- release:
  <https://github.com/stephenlclarke/container-compose/releases/tag/current>

It is not evidence for this slice.

## Required closeout on the replacement MBP

1. Fetch `origin` and confirm `main` still contains
   `4fe88b796fe2b4b3008ccc7da8d284cedd4235c4`.
2. Monitor exact-main runs `30253458586` and `30253458571`; confirm all five
   workflows above finish green.
3. Inspect CI `30253458586` and require the `SonarQube scan` step to pass.
4. Query SonarCloud project `stephenlclarke_container-compose2` and require:
   - analysis revision equal to exact validated main;
   - quality gate `OK`;
   - zero unresolved issues;
   - zero unresolved security hotspots;
   - A reliability, security, and maintainability ratings.
5. Find the automatic `Prebuilt Binaries` run created from CI `30253458586`
   and wait for it to finish.
6. Compare its Package timings with baseline run `30235634675`:
   - old SwiftPM cache transfer: 10m00s / 2,134,173,923 bytes;
   - old `setup-go` cache path: 19m19s / 1,624,881,811-byte attempted restore.
7. Verify the refreshed `current` prerelease:
   - exact target commit;
   - prerelease, not draft;
   - seven assets;
   - both checksum sidecars;
   - both GitHub attestations;
   - Homebrew tap commit and matched formula version;
   - release-highlight JSON and quality snapshot;
   - live GIF metadata/hash and the tape instruction counts above.
8. Update these checked-in documents with the actual evidence:
   - this handoff;
   - `PR-upstream-maintenance-20260727.md`;
   - `PR-release-dependency-cache-overhead.md`.
9. Commit the evidence as a signed documentation commit on
   `docs/upstream-maintenance-closeout-20260727`, push it, open a PR, obtain an
   exact-head connector review, run the thread-aware fetcher, and merge.
10. If the docs-only merge becomes newer than the released target, dispatch
    full CI for exact final `main` and republish `current` from that exact
    revision. Do not leave the mutable prerelease behind final `main`.
11. Refresh this handoff with final run, Sonar, release, tap, GIF, and Slack END
    identities.
12. Fully reread the Slack skills, send the detailed slice END, then begin a
    new slice only after a new Slack START.

## Upstream state at merge

Freshly fetched Apple/fork baselines:

- `apple/container`: Apple
  `d1d763530df3c6a326dbae7f0c0a59a335808045`; fork
  `5796a79ee3e59c16098d086278c072740d519ee8`; Apple-only 0; fork-only
  non-merge 276
- `apple/containerization`: Apple
  `74ace148ded72f7bb3c878b142e4962ae668adf4`; fork
  `164088e02e16ed80e536d0c59822b09931d213df`; Apple-only 0; fork-only
  non-merge 110
- `apple/container-builder-shim`: Apple
  `267b5ab98e1d7db7d98af98bdc90578bf5fd3192`; fork
  `f97cddf5b3aae2426a094613793c11c41b1d2e53`; Apple-only 0; fork-only
  non-merge 28

No open Dependabot/Renovate PR existed in the runtime, containerization,
builder-shim, Compose, or tap repositories.

Stephen-authored Apple proposals had no requested author change:

- `apple/container#1934`
- `apple/container#1935`
- `apple/container#1965`
- `apple/containerization#799`

Recheck all remotes, bot PRs, authored proposals, and connector comments after
moving hosts; this snapshot is not a substitute for a fresh audit.

## Worktrees and shared-runtime boundary

Preserve these user changes:

- `/Users/sclarke/github/container-compose`
  - modified `Package.resolved`
  - untracked `Packages/`
- `/Users/sclarke/github/containerization`
  - untracked `.vscode/`

Do not clean, reset, overwrite, or fold them into this slice.

The previous MBP shared its global Container service with a devcontainer
session. Immediately before PR #166 merged, all visible devcontainer BuildKit
containers were stopped. Once devcontainer work runs on a different MBP, that
local service conflict is removed, but still inspect the service before any
runtime install, stop, reset, or live parity run.

## Next parity blockers

Do not start these until this slice is fully published and closed:

1. Drain package-compatibility preflight stdout/stderr concurrently so a full
   child pipe cannot deadlock.
2. Preserve inherited OCI `VOLUME` declarations in `compose commit`.
3. Replace archive-mode `compose cp` host staging with direct runtime streams
   so ownership metadata can be preserved.

Continue the ordered inventory in
`docs/reviews/CONTAINER-STACK-CRITICAL-REVIEW-2026-07-24.md` after these three
confirmed P1 items.
