# Cross-MBP handoff: upstream maintenance

Updated: 2026-07-27 11:56 BST

## Stop point

The source changes for this slice are merged and the exact-main publication
gates have closed green. The mutable `current` prerelease now points at the
merge, the package artefacts and Homebrew formulas are aligned, and SonarCloud
has indexed the exact revision.

The remaining closeout work is documentation review/merge and the final Slack
END notification. Do not begin the next parity slice until that closeout is
complete.

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

## Exact-main publication evidence

All runs target exact merge
`4fe88b796fe2b4b3008ccc7da8d284cedd4235c4`.

- CI
  [30253458586](https://github.com/stephenlclarke/container-compose/actions/runs/30253458586):
  green. `Run coverage gate`, `Run built CLI smoke`, and `SonarQube scan`
  passed. The `SonarQube scan` step ran from 09:48:54 to 09:49:50 UTC.
- CodeQL
  [30253458549](https://github.com/stephenlclarke/container-compose/actions/runs/30253458549):
  green
- Quality
  [30253458554](https://github.com/stephenlclarke/container-compose/actions/runs/30253458554):
  green
- Documentation
  [30253458571](https://github.com/stephenlclarke/container-compose/actions/runs/30253458571):
  green
- immutable archive verification
  [30253458622](https://github.com/stephenlclarke/container-compose/actions/runs/30253458622):
  green

The automatic `Prebuilt Binaries` workflow from CI finished green:

- [30255646679](https://github.com/stephenlclarke/container-compose/actions/runs/30255646679),
  event `workflow_run`, head
  `4fe88b796fe2b4b3008ccc7da8d284cedd4235c4`
- Package job [89943524792](https://github.com/stephenlclarke/container-compose/actions/runs/30255646679/job/89943524792):
  14m18s total, from 09:51:06 to 10:05:24 UTC
- Compared with baseline package run
  [30235634675](https://github.com/stephenlclarke/container-compose/actions/runs/30235634675),
  the SwiftPM package cache restore step was removed and the Go setup cache was
  disabled. Baseline package duration was 43m01s, including a 10m00s
  2,134,173,923-byte SwiftPM cache transfer and a 19m19s
  1,624,881,811-byte Go cache restore attempt. Current `Set up Go` completed in
  0s, `Build matched runtime package` completed in 2m50s, `Build release
  package` completed in 2m31s, and the live VHS recording completed in 6m38s.

SonarCloud project `stephenlclarke_container-compose2` is aligned:

- latest analysis: `2026-07-27T09:49:07+0000`
- revision: `4fe88b796fe2b4b3008ccc7da8d284cedd4235c4`
- quality gate: `OK`
- unresolved issues: 0
- unresolved security hotspots: 0
- reliability, security, and maintainability ratings: A
- bugs, vulnerabilities, code smells, and security hotspots: 0

The refreshed `current` prerelease is valid slice evidence:

- target:
  `4fe88b796fe2b4b3008ccc7da8d284cedd4235c4`
- published: 2026-07-27 10:05:13 UTC
- release:
  <https://github.com/stephenlclarke/container-compose/releases/tag/current>
- prerelease: true
- draft: false
- seven release assets:
  - `container-compose-demo-current.gif`,
    GitHub asset digest
    `sha256:a7e2821befbd1be4c6a2c7e0d807322aa18dd76d240d62233b32620dd2a9840a`
  - `container-compose-plugin-current-4fe88b796fe2-arm64.tar.gz`,
    GitHub asset digest and checked artefact SHA-256
    `cc51d5dea4feabf84a66fc024a22b067b61a307f078bf23a48fa3ea1d32771ac`
  - `container-compose-plugin-current-4fe88b796fe2-arm64.tar.gz.sha256`
  - `container-current-4fe88b796fe2-arm64.tar.gz`,
    GitHub asset digest and checked artefact SHA-256
    `64b47eb5377b7f60c70381008510656d2a88dee1b4c625e349da2eba6ab840b2`
  - `container-current-4fe88b796fe2-arm64.tar.gz.sha256`
  - `quality-snapshot-current.svg`,
    GitHub asset digest
    `sha256:cdc66f407cc8c883bf09e1b4efcad056908e577354a47611d36119e337dcbcf5`
  - `release-highlights-current-4fe88b796fe2.json`,
    GitHub asset digest
    `sha256:2fd2a2ca64f2cce34d5abc20892d0284ea469c6a7d4748ab0a5a0f05c1a444bb`
- checksum sidecars verified locally with `shasum -a 256 -c`
- both package attestations verified locally with `gh attestation verify` after
  selecting the keyring-backed GitHub token:
  - `container-compose-plugin-current-4fe88b796fe2-arm64.tar.gz`
  - `container-current-4fe88b796fe2-arm64.tar.gz`
- Homebrew tap commit
  `5d53619c83bd8a2b1b47638d8d99d0c817d1ed17` updates
  `container-current.rb` and `container-compose-current.rb` to
  `current.895.4fe88b796fe2`, with matched asset names and SHA-256 values
- downloaded release-highlight JSON contains the expected top-level keys:
  `base`, `components`, `composeVersion`, `head`, `highlights`,
  `releaseLabel`, `releaseTag`, and `schemaVersion`
- downloaded live GIF is GIF89a, 1600 x 720, 3,306,908 bytes, SHA-256
  `a7e2821befbd1be4c6a2c7e0d807322aa18dd76d240d62233b32620dd2a9840a`
- checked-in README tape contains 16 `Type`, 16 `Enter`, 14 `Wait+Screen`,
  zero `Replay`, and zero `Marker` directives

## Remaining closeout

1. Commit this evidence as a signed documentation commit on
   `docs/upstream-maintenance-closeout-20260727`, push it, open a PR, obtain an
   exact-head connector review, run the thread-aware fetcher, and merge.
2. If the docs-only merge becomes newer than the released target, dispatch full
   CI for exact final `main` and republish `current` from that exact revision.
   Do not leave the mutable prerelease behind final `main`.
3. Refresh this handoff with final run, Sonar, release, tap, GIF, and Slack END
   identities.
4. Fully reread the Slack skills, send the detailed slice END, then begin a new
   slice only after a new Slack START.

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

The replacement MBP now has `/Users/sclarke/github/container-compose` clean on
this closeout branch after fast-forwarding `main`. `/Users/sclarke/github/homebrew-tap`
was also fast-forwarded cleanly to the published formula commit above. Continue
to inspect status before any runtime install, reset, or live parity run.

The previous MBP shared its global Container service with a devcontainer
session. Immediately before PR #166 merged, all visible devcontainer BuildKit
containers were stopped. Once devcontainer work runs on a different MBP, that
local service conflict is removed, but still inspect the service before any
runtime install, stop, reset, or live parity run.

## Next parity blockers

CC-003 is complete in signed Compose commits `81d32eb2`, `96ac7830`,
`045d020c`, `9db8f060`, `e0ad1dfe`, `4bf2eac6`, `3ed87228`, `fbe0ce05`,
`b65d18a6`, `62a40d48`, `b07e9da8`, and `5b6f4880`:
package-compatibility stdout and stderr now drain concurrently through the
shared process runner while retaining only a bounded prefix and exact omitted
byte count for each stream. Cancellation owns the child process group and
remains structured through both awaits. The signal proxy is active before the
child task can start, synchronously registers delivered handlers, drains
dispatch-source cancellation, and awaits those handlers before accepting the
operation result. Host signals therefore cancel and reap the preflight group
before the CLI returns the corresponding shell status. Diagnostics are bounded
at a 64 KiB raw-stream boundary with complete valid UTF-8 scalars and exact
omitted source-byte counts. The boundary is measured from the absolute
raw-stream start, so trimming leading whitespace cannot shift the UTF-8
lookahead or split a valid scalar. Content beginning beyond a
whitespace-consumed display budget returns an exact truncation marker rather
than an empty diagnostic. The
formatter scans raw data once and retains only the
bounded rendered prefix and offsets without changing public `CommandResult`
equality or the unbounded public runner API. Test commit `592266a7` runs a
16 MiB packaged-CLI failure in an isolated process, enforces a 320 MiB maximum
resident-memory ceiling, and passes with Address Sanitizer. The final focused
sanitizer runs pass 25 package-preflight tests across five suites and three
signal-proxy tests in one suite. Signed correction `b65d18a6`
preserves stderr priority when
the retained prefix is whitespace but omitted bytes remain, with an exact
65,552-byte real-child regression. Signed correction `62a40d48` adds a
leading-whitespace/four-byte-scalar boundary regression. Signed correction
`b07e9da8` reports one-byte content that starts after a 64 KiB leading-whitespace
budget. Signed correction `5b6f4880` proves a delivered handler cannot race the
proxied operation result. The complete local gate passes 1,266 Swift tests in
46 suites with 92.81% Swift and 89.88% Go coverage.

CC-004 is complete.
`ComposeCommitImageArchive` seeds the committed OCI volume map from inherited
image declarations before unioning repeated shell-form and JSON-form
`--change VOLUME` targets. Four focused volume tests pass, including
service-platform selection, duplicate, and multi-target cases. The strict live
probe builds matched base images with `VOLUME ["/image-data", "/shared-data"]`,
adds `/added-data` and `["/logs", "/shared-data"]`, and confirms Docker Compose
v5.3.1 and the installed Container-backed Compose binary both retain the same
four targets. PR
[#173](https://github.com/stephenlclarke/container-compose/pull/173) also
resolves every inherited OCI config field from the selected service-platform
variant. The successful explicit-platform path converts the local image to an
`ImageResource` once instead of three times; unavailable or failed variant
selection retains the default-metadata fallback with at most two reads. No
Apple runtime fork or stack pin changes.

The next parity blocker is:

1. Replace archive-mode `compose cp` host staging with direct runtime streams
   so ownership metadata can be preserved.

Continue the ordered inventory in
`docs/reviews/CONTAINER-STACK-CRITICAL-REVIEW-2026-07-24.md` after this
remaining confirmed P1 item is complete.
