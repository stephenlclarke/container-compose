# Upstream Drafts

This directory is the durable handoff area for Apple-facing issue and pull request drafts that unblock `container-compose`.

## Slice Rules

- Each implementation slice must map to one future Apple pull request per Apple repository. If a capability needs both `apple/containerization` and `apple/container`, split it into two PR-shaped slices: one lower-runtime PR and one API/CLI PR.
- Keep Compose-specific behavior in `container-compose`. Apple-facing PRs should expose generic runtime primitives, API routes, CLI flags, and tests, not Compose service fan-out, prefixes, colors, selected-service filtering, or Docker Compose output policy.
- Every `PR*.md` draft must include a `Commit Tracking` section. Constructible PR drafts must list the exact commit IDs to squash. Planning-only drafts must say they are not constructible yet and name the missing repo/branch commit that must be cut before a PR can be raised.
- Before selecting a slab or slice, inspect current open issues and pull requests for `apple/container` and `apple/containerization`. Reference matching upstream work in the issue and PR drafts rather than opening duplicates.
- When Docker behavior is the target, check Docker's own documentation and the Docker Compose implementation before settling the slice boundary. Record the relevant docs/source links in the issue and PR drafts when they affect shape, output, filtering, or test fixtures.
- Keep the draft files in this repository even when the code lives in sibling forks. That makes `container-compose` the single project handoff for runtime gaps, upstream links, and commit IDs.

## Final Upstream Review Gate

After the intended `container-compose` functionality is implemented and the sibling forks contain the supporting runtime/API/CLI code, do a full Apple-maintainer review before raising or refreshing upstream PRs.

The review must cover every potential PR independently:

- Confirm the PR is still the narrowest useful Apple-facing slice and maps to one repository unless a lower-runtime dependency genuinely requires a separate `apple/containerization` PR.
- Re-check current open Apple issues and PRs, then update each draft with the matching references, stacking decision, and why any similar upstream work was or was not used as the base.
- Verify the listed commit IDs still construct the intended PR and that no unrelated `container-compose` policy, Docker Compose formatting, private-machine assumption, or temporary fork-only behavior has leaked into Apple runtime code.
- Review the code as an Apple maintainer and as any likely code owner for the touched area, then fix findings before drafting the PR text.
- Re-run the focused validation for each slice plus repository-level hygiene checks, and keep optional Docker / Docker Compose V2 parity checks local-only and out of Apple CI.
- Update the affected `ISSUE*.md`, `PR*.md`, `PLAN.md` and `STATUS.md` files with findings, fixes, validation, dependencies, and any residual risk.

## Current Inventory

Refreshed on 2026-06-22.

| Area | Paths | Notes |
| --- | --- | --- |
| Compose-owned compatibility slices | `ISSUE-*.md`, `PR-*.md` at the repository root | Historical plugin PR drafts. New or moved drafts should prefer a topic folder under `docs/upstream/`. |
| Copy slices | `docs/upstream/copy/` | Compose-facing copy follow-link and archive drafts with commit tracking. |
| Process listing / `top` slice | `docs/upstream/process-list/` | Compose-facing PID-only `top` drafts with commit tracking. |
| Mirrored `apple/container` runtime drafts | `docs/upstream/apple-container/` | Issue/PR drafts mirrored from `/Users/sclarke/github/container` so runtime PR text is available from this repo. |
| Mirrored `apple/containerization` runtime drafts | `docs/upstream/apple-containerization/` | Issue/PR drafts mirrored from `/Users/sclarke/github/containerization`. |
| Event-stream slab | `docs/upstream/events/` | Current handoff drafts for the Apple runtime event primitive, event time filters, Compose-owned `events --json [SERVICE...]`, Compose-owned `events --json --since/--until [SERVICE...]`, and Compose-owned default text event formatting slices. |

## Refresh Commands

Use these when sibling runtime drafts change:

```sh
rsync -a --prune-empty-dirs --exclude='.git/**' --exclude='.build/**' --exclude='.github/**' --include='*/' --include='ISSUE*.md' --include='PR*.md' --exclude='*' /Users/sclarke/github/container/ docs/upstream/apple-container/
rsync -a --prune-empty-dirs --exclude='.git/**' --exclude='.build/**' --exclude='.github/**' --include='*/' --include='ISSUE*.md' --include='PR*.md' --exclude='*' /Users/sclarke/github/containerization/ docs/upstream/apple-containerization/
```

After refreshing, run:

```sh
markdownlint docs/upstream
git diff --check
```
