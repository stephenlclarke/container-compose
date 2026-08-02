# Fork Commit Classifications

Updated: 30 July 2026

This review classifies every patch-unique non-merge commit in the three
Stephen-supported Apple forks. The machine-readable source is
[FORK-COMMIT-CLASSIFICATIONS.json](FORK-COMMIT-CLASSIFICATIONS.json). Each
commit belongs to exactly one reviewed slice with one owner, reason, and
upstream disposition.

## Baseline

The repositories were fetched with `git fetch --all --prune --no-tags`.
Patch-unique commits were enumerated with:

```sh
git log --cherry-pick --right-only --no-merges \
  <apple-main>...<stephen-main>
```

| Repository | Apple `main` | Stephen `main` | Apple-only | Fork-only | Classified non-merge commits |
| --- | --- | --- | ---: | ---: | ---: |
| `container` | `6e65319fe476ffe8db8ddaf828a537ed36fe2859` | `8657c4b8685865c8889b0171d953342fc9f427a7` | 0 | 338 | 299 |
| `containerization` | `ff44a5b683c80fceab875dba8a20ed24d7648c07` | `971fc7e5e27467ebd6227e1ae54f3e5c23de87b4` | 0 | 135 | 112 |
| `container-builder-shim` | `267b5ab98e1d7db7d98af98bdc90578bf5fd3192` | `61832d4ca91715180a84dec0eab091170174c43c` | 0 | 34 | 29 |
| **Total** | | | **0** | **507** | **440** |

The graph-ahead count includes merge commits. The classification count excludes
merges and patch-equivalent commits so the registry covers semantic fork work.

## Dispositions

| Classification | Commits | Disposition |
| --- | ---: | --- |
| `support-maintenance` | 310 | Retain independent bug fixes, tests, CI, release engineering, dependency pins, documentation, and review corrections. Split generally useful fixes during FORK-105. |
| `generic-runtime-primitive` | 105 | Retain typed VM, guest, archive, network, process, storage, resource, and BuildKit capabilities below Compose. Keep Apple-shaped handoffs and independently reviewable upstream slices. |
| `temporary-upstream-port` | 21 | Retain only until the named Apple PR lands or an equivalent change is verified. Published duplicate history is not rewritten. Remove remaining source duplication through normal follow-up commits. |
| `rejected-compose-policy` | 4 | Remove runtime config, secret, and Keychain storage added solely for Compose. Their supported behaviour now belongs to the Compose provider. |

No current commit is unclassified or assigned to more than one slice.

## Review Findings And FORK-105 Progress

The four rejected Compose-policy commits have been removed on published,
validated branches without changing the fork default branches:

- `container` persistent config storage and its handoff:
  `f1f8ce6b33fa`, `7261ac9cfe33`; the removal is at
  `stephenlclarke/container:upstream/remove-compose-resource-stores`
  `9b1a49b53ff73417d1b4cfbf39fa5a9dffa06023`.
- `container` local secret storage: `468a85e233dd`; the removal is in the same
  `container` branch and head.
- `containerization` opaque Keychain storage: `9f63d1890ebb`; the removal is at
  `stephenlclarke/containerization:upstream/remove-compose-keychain-store`
  `66f0963cbe2b59170f9164c4dae5828baf59fdd8`.

Compose pins those exact heads through
`3d77ec228c7f55a04f689d5e1453752fc0c27f72`, now contained in the Compose
default branch. Full lower-repository tests and checks passed, followed by
`HAWKEYE_AUTO_INSTALL=1 make ci` in Compose. The historical commits remain
classified until the lower-repository removal branches are integrated into
their fork default branches.

Four early `containerization` ports have now been reconciled with Apple
`main` at `ff44a5b683c80fceab875dba8a20ed24d7648c07`:

- Apple #685 freeze/thaw API: local `1eaaee814dad`, Apple `5887dc55f314`,
  stable patch ID `366f046411cb`.
- Apple #700 trim API: local `28021979ddb5`, Apple `6b7b42ca3efe`,
  stable patch ID `336cc506946d`.
- Apple #775 configurable EXT4 journal mode: local `cff8d5866ac8`, Apple
  `a132341dc61b`, stable patch ID `9a20d1a83363`.
- Apple #798 CloudHypervisor SwiftPM exclusion: local `131b1e8344ad`, Apple
  `2a591c2aeed6`. The current manifest uses Apple's merged hunk exactly.

A zero-context current-tree comparison found no fork-only freeze/thaw, trim,
journal-mode, or README-exclusion line. There is therefore no source duplicate
to delete. Only immutable published history remains, and it will not be
rewritten.

The remaining temporary ports track Apple #1735, #1997, #2031, #753/#766,
Apple #799, #820, #821, `container-builder-shim` #83, and
`container-builder-shim` #87. The local #813 redaction predates Apple's merged
implementation and remains patch-unique, so its registry entry now requires
explicit reconciliation rather than treating an upstream merge as sufficient.
Every exact commit and deletion condition is recorded in the JSON registry.

Manual subject and slice review corrected one generated candidate:
`941a5d5961b2` introduced OOM-killer configuration but was explicitly reverted
by `0535f50ca663`; both are maintenance history, not an active runtime
capability.

## Automated Gate

`make fork-classifications-check` fetches the three fork and Apple refs, then
validates only the registry. `make upstream-divergence-check` runs the same
classification validation and also checks worktree, push, and non-destructive
merge state. The classification gate fails when:

- an exact Apple or Stephen baseline head changes;
- a current patch-unique non-merge commit is absent;
- a removed or patch-equivalent commit remains in the registry;
- a commit appears in more than one slice;
- a slice lacks a valid classification, owner, reason, or upstream disposition.

`make upstream-divergence-release-check` adds the existing requirement that
every Stephen fork contains current Apple `main`.

The gate never classifies a new commit automatically. A maintainer must inspect
the change, assign it to one explicit slice, update the reviewed heads, and
rerun the strict report.

## Current Refresh State

All three supported fork default branches contain the fetched Apple heads at
this refresh. The nine newly patch-unique `container` commits were reviewed:
six release, signing, and dependency-pin changes are support maintenance; the
XPC ownership correction and two ProcessIO backpressure commits are generic
runtime primitives. The builder-shim DNS configuration commit is also a
generic runtime primitive. No commit was assigned automatically.

The registry records fork ownership; it does not promote a runtime or Compose
stack pin. Release promotion must continue through the exact stack references,
normal signed commits, and the full linked-stack gates without rewriting
published history.
