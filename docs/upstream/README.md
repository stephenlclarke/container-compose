# Upstream Drafts

This directory is the durable handoff area for current Apple-facing issue and
pull request drafts that unblock `container-compose`. It is not a project
history or an operational runbook: current installation, release, support, and
build instructions live at the repository root.

## Slice Rules

- Each implementation slice must map to one future Apple pull request per Apple repository. If a capability needs both `apple/containerization` and `apple/container`, split it into two PR-shaped slices: one lower-runtime PR and one API/CLI PR.
- Keep Compose-specific behavior in `container-compose`. Apple-facing PRs should expose generic runtime primitives, typed resource models, API routes, native lifecycle operations, and tests, not Compose service fan-out, prefixes, colors, selected-service filtering, Docker-shaped parsers, or Docker Compose output policy.
- Follow the Apple maintainer guidance on [apple/container#1769](https://github.com/apple/container/pull/1769#issuecomment-4780439328): do not create or keep Apple-facing drafts whose only value is Docker CLI compatibility. If a local Apple fork commit currently contains a Docker-shaped flag parser, document it as a temporary validation bridge only when the typed primitive is still a useful Apple slice.
- `container-compose` owns Docker and Docker Compose compatibility: Compose file parsing, Docker timestamp/duration strings, Docker flag aliases, dry-run command text, project/service filtering, output formatting, and compatibility diagnostics. Apple drafts can cite Docker behavior as background, but the requested Apple surface should be Apple-native and typed wherever possible.
- Every `PR*.md` draft must include a `Commit Tracking` or `Intended Review Delta` section. Constructible PR drafts must list the exact commit IDs to squash. Planning-only drafts must say they are not constructible yet and name the missing repository commit that must be cut before a PR can be raised.
- Before selecting a slab or slice, inspect current open issues and pull requests for `apple/container` and `apple/containerization`. Reference matching upstream work in the issue and PR drafts rather than opening duplicates.
- When Docker behavior is the target, check Docker's own documentation and the Docker Compose implementation before settling the slice boundary. Record the relevant docs/source links in the issue and PR drafts when they affect shape, output, filtering, or test fixtures.
- Keep the draft files in this repository even when the code lives in sibling forks. That makes `container-compose` the single project handoff for runtime gaps, upstream links, and commit IDs.
- Treat this `container-compose` tree as the only home for handoff documentation. Do not keep `ISSUE-*.md` or `PR-*.md` draft files in the sibling `container`, `containerization`, or `container-builder-shim` fork worktrees; if one is created there while shaping code, move it into the matching `docs/upstream/` folder here and remove the fork copy.
- Keep drafts current. Remove obsolete branch names, completed migration notes, dated snapshots, and superseded implementation procedures instead of preserving project history here. Current branch and release rules live in [BUILD.md](../../BUILD.md).
- Every open Apple pull request with code we may need to recover must also have
  an immutable, stephenlclarke-owned `upstream-pr-NUMBER-SHORTSHA` branch recorded in
  [PR-ARCHIVE.json](PR-ARCHIVE.json). Never force-push, delete, or retarget an
  archive branch. Add a new snapshot when an upstream PR head changes.

## Final Upstream Review Gate

After the intended `container-compose` functionality is implemented and the sibling forks contain the supporting runtime/API/CLI code, do a full Apple-maintainer review before raising or refreshing upstream PRs.

The review must cover every potential PR independently:

- Confirm the PR is still the narrowest useful Apple-facing slice and maps to one repository unless a lower-runtime dependency genuinely requires a separate `apple/containerization` PR.
- Re-check current open Apple issues and PRs, then update each draft with the matching references, stacking decision, and why any similar upstream work was or was not used as the base.
- Verify the listed commit IDs still construct the intended PR and that no unrelated `container-compose` policy, Docker Compose formatting, private-machine assumption, or temporary fork-only behavior has leaked into Apple runtime code.
- Review the code as an Apple maintainer and as any likely code owner for the touched area, then fix findings before drafting the PR text.
- Re-run the focused validation for each slice plus repository-level hygiene checks, and keep optional Docker / Docker Compose V2 parity checks local-only and out of Apple CI.
- Update the affected `ISSUE*.md`, `PR*.md`, and `STATUS.md` files with findings, fixes, validation, dependencies, and any residual risk.

## Current Inventory

| Area | Paths | Notes |
| --- | --- | --- |
| Current Apple review | `docs/upstream/APPLE-UPSTREAM-REVIEW.md` | Live disposition of affected bugs, approved open pull requests, local ports, and unresolved follow-up work. |
| Immutable PR code archive | `docs/upstream/PR-ARCHIVE.json` | Full-SHA, stephenlclarke-owned snapshots of every open upstream proposal that the stack depends on. [Verify Upstream PR Archives](../../.github/workflows/upstream-pr-archive.yml) checks them daily. |
| Compose-owned compatibility slices | `docs/upstream/container-compose/` | Plugin-owned issue/PR drafts with commit tracking. These drafts may describe Docker/Compose compatibility and the temporary command-vector bridge while the typed service-create adapter is still being wired. |
| Copy slices | `docs/upstream/copy/` | Compose-facing copy follow-link and archive drafts with commit tracking. Runtime copy primitives live under the Apple folders. |
| Process listing / `top` slice | `docs/upstream/process-list/`, `docs/upstream/apple-container/`, and `docs/upstream/apple-containerization/` | Compose-facing Docker-shaped `top` drafts plus generic Apple runtime/API/init-image handoffs and commit tracking. |
| `apple/container` runtime drafts | `docs/upstream/apple-container/` | Apple-shaped typed runtime issue/PR drafts maintained in this repo even when the code lives in `/Users/sclarke/github/container`. |
| `apple/containerization` runtime drafts | `docs/upstream/apple-containerization/` | Lower-runtime issue/PR drafts maintained in this repo even when the code lives in `/Users/sclarke/github/containerization`. |
| `apple/container-builder-shim` build-context drafts | `docs/upstream/apple-container-builder-shim/` | Builder-shim issue/PR drafts maintained here while the code lives in `/Users/sclarke/github/container-builder-shim`. |
| Event-stream slab | `docs/upstream/events/` | Current handoff drafts for the Apple runtime event primitive, event time filters, Compose-owned `events --json [SERVICE...]`, Compose-owned `events --json --since/--until [SERVICE...]`, and Compose-owned default text event formatting slices. |

## Fork Documentation Audit

Use these to confirm handoff docs have not drifted back into sibling forks:

```sh
find /Users/sclarke/github/container \( -name .build -o -name .git \) -prune -o \( -name 'ISSUE-*.md' -o -name 'ISSUES-*.md' -o -name 'PR-*.md' \) -print
find /Users/sclarke/github/containerization \( -name .build -o -name .git \) -prune -o \( -name 'ISSUE-*.md' -o -name 'ISSUES-*.md' -o -name 'PR-*.md' \) -print
find /Users/sclarke/github/container-builder-shim \( -name .build -o -name .git -o -path '*/vendor/*' \) -prune -o \( -name 'ISSUE-*.md' -o -name 'ISSUES-*.md' -o -name 'PR-*.md' \) -print
```

These commands should print nothing. After moving or editing handoff docs here, run:

```sh
markdownlint docs/upstream
git diff --check
```
