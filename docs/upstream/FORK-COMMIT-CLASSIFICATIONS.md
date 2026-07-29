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

## Review Findings

Four commits are confirmed removal candidates for FORK-105:

- `container` persistent config storage and its handoff:
  `f1f8ce6b33fa`, `7261ac9cfe33`
- `container` local secret storage: `468a85e233dd`
- `containerization` opaque Keychain storage: `9f63d1890ebb`

Three early `containerization` ports correspond to Apple changes that are
already merged:

- Apple #685 freeze/thaw API: `1eaaee814dad`
- Apple #700 trim API: `28021979ddb5`
- Apple #775 configurable EXT4 journal mode: `cff8d5866ac8`

Apple #798 is also merged; the earlier fork exclusion at `131b1e8344ad`
remains classified as a temporary port until normal Apple reconciliation proves
that no source delta remains.

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

## Current Refresh Blocker

`containerization` and `container-builder-shim` pass the non-destructive Apple
merge check. Current Apple `container` conflicts with the supported fork in:

- `Package.swift`
- `Package.resolved`
- `Sources/ContainerBuild/BuildFSSync.swift`
- `Sources/ContainerBuild/URL+Extensions.swift`
- `Sources/SocketForwarder/TCPForwarder.swift`
- `Tests/ContainerBuildTests/BuildFSSyncTests.swift`

Those conflicts come from reconciling Apple #2027 and the #2038
`containerization` 0.40.1 pin with independently strengthened fork behaviour.
They must be resolved and validated in an isolated fork-sync branch before a
stable release. This classification review does not silently choose either
side.
