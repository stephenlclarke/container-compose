# Fork Commit Classifications

Updated: 29 July 2026

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
| `container` | `6e65319fe476ffe8db8ddaf828a537ed36fe2859` | `367430446959e3048da37f5f64d3c10e1293d3de` | 2 | 327 | 290 |
| `containerization` | `7800b4642171561c95b5f55500b19e5dce5acd45` | `043193efa5f1a2e21a240041d6edd71d7673739e` | 2 | 133 | 112 |
| `container-builder-shim` | `267b5ab98e1d7db7d98af98bdc90578bf5fd3192` | `f97cddf5b3aae2426a094613793c11c41b1d2e53` | 0 | 33 | 28 |
| **Total** | | | **4** | **493** | **430** |

The graph-ahead count includes merge commits. The classification count excludes
merges and patch-equivalent commits so the registry covers semantic fork work.

## Dispositions

| Classification | Commits | Disposition |
| --- | ---: | --- |
| `support-maintenance` | 304 | Retain independent bug fixes, tests, CI, release engineering, dependency pins, documentation, and review corrections. Split generally useful fixes during FORK-105. |
| `generic-runtime-primitive` | 101 | Retain typed VM, guest, archive, network, process, storage, resource, and BuildKit capabilities below Compose. Keep Apple-shaped handoffs and independently reviewable upstream slices. |
| `temporary-upstream-port` | 21 | Retain only until the named Apple PR lands or an equivalent change is verified. Published duplicate history is not rewritten. Remove remaining source duplication through normal follow-up commits. |
| `rejected-compose-policy` | 4 | Remove runtime config, secret, and Keychain storage added solely for Compose. Their supported behaviour now belongs to the Compose provider. |

No current commit is unclassified or assigned to more than one slice.

## Review Findings And FORK-105 Progress

The four rejected Compose-policy commits have been removed on published,
validated branches without changing the fork default branches:

- `container` persistent config storage and its handoff:
  `f1f8ce6b33fa`, `7261ac9cfe33`; the removal is at
  `stephenlclarke/container:refactor/remove-compose-resource-stores`
  `9b1a49b53ff73417d1b4cfbf39fa5a9dffa06023`.
- `container` local secret storage: `468a85e233dd`; the removal is in the same
  `container` branch and head.
- `containerization` opaque Keychain storage: `9f63d1890ebb`; the removal is at
  `stephenlclarke/containerization:refactor/remove-compose-keychain-store`
  `66f0963cbe2b59170f9164c4dae5828baf59fdd8`.

Compose pins those exact heads on
`stephenlclarke/container-compose:refactor/remove-compose-resource-stores` at
`3d77ec228c7f55a04f689d5e1453752fc0c27f72`. Full lower-repository tests and
checks passed, followed by `HAWKEYE_AUTO_INSTALL=1 make ci` in Compose. The
historical commits remain classified until the removal branches are integrated
into the fork default branches.

Four early `containerization` ports have now been reconciled with Apple
`main` at `7800b4642171561c95b5f55500b19e5dce5acd45`:

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
Apple #799, #813, #820, #821, `container-builder-shim` #83, and
`container-builder-shim` #87. Their exact commits and deletion conditions are
recorded in the JSON registry.

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

The earlier Apple #2027/#2038 `container` conflicts and Apple #822/#824
`containerization` updates have been resolved and validated on isolated
integration branches. The Compose integration head
`0d9a111609eed8d4bc7e3503f18492059b0f194e` passed full CI before the
FORK-105 removals above were applied and revalidated.

The fork default branches remain unchanged, so the registry baseline heads and
their ahead/behind counts still describe those default branches. Release
promotion must integrate the validated branches through normal signed commits
without rewriting published history, then regenerate this registry against the
new default heads.
