# Fork Commit Classifications

Updated: 29 August 2026

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
| `container` | `d65874da36551f4c948711fae164820a3175bc5d` | `ba9566840b087ac6d61ebb8be52b90ca03ba07cc` | 0 | 720 | 618 |
| `containerization` | `2faaf9b4aff48a4745ef3d26c3f1450c1228fdf0` | `e5a92e86bf03eb2cc244b3b47b0413b3935abfe4` | 0 | 269 | 220 |
| `container-builder-shim` | `e18d2182fd060dbf1c68113a74e7564d563dde27` | `db3e99cc3d19b9a328eb51be3a023a178f80ee81` | 0 | 46 | 39 |
| **Total** | | | **0** | **1035** | **877** |

The graph-ahead count includes merge commits. The classification count excludes
merges and patch-equivalent commits so the registry covers semantic fork work.

## Dispositions

| Classification | Commits | Disposition |
| --- | ---: | --- |
| `support-maintenance` | 624 | Retain independent bug fixes, tests, CI, release engineering, dependency pins, documentation, and review corrections. Split generally useful fixes during FORK-105. |
| `generic-runtime-primitive` | 228 | Retain typed VM, guest, archive, network, process, storage, resource, logging, Engine API, and BuildKit capabilities below Compose. Keep Apple-shaped handoffs and independently reviewable upstream slices. |
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
this refresh. The 298 newly patch-unique non-merge commits were inspected by
subject and owning layer: 253 in `container`, 41 in `containerization`, and
four in `container-builder-shim`. New typed runtime, Engine API, logging,
network, storage, sandbox, and copy capabilities were assigned to the generic
runtime slice. Bug fixes, tests, CI, documentation, dependency work,
packaging, review corrections, and removal of rejected Compose-owned policy
were assigned to support maintenance. No temporary port or rejected-policy
disposition was inferred for a new commit, and no published history was
rewritten.

The 10 August 2026 incremental refresh advances Apple `container` through
`ff5aa8a03b7d`, Apple `containerization` through `5427fd21ded4`, and adds three
reviewed support-maintenance commits: the bounded Container test-process exit
wait, Container's exact Containerization dependency pin, and the bounded
Containerization CodeQL build timeout. No generic-runtime, temporary-port, or
rejected-policy classification changed in this refresh.

The final Container refresh also incorporates Apple's volume-name validation
at `ff5aa8a03b7d` and the signed conflict resolution at `e2378a25873a`. Both
are upstream or merge history, so the graph-ahead count increases while the
patch-unique non-merge classification count and disposition totals remain
unchanged.

The 11 August 2026 maintenance refresh advances the Container fork through
`0e22d5eb3e5f` and classifies four independently reviewed release repairs as
support maintenance: isolated init-bootstrap application and log roots,
explicit HTTPS for programmatic bootstrap image pulls, retained init archive
loading during clean release validation, and deterministic help-path health
tests that cannot discover plugins from an installed release candidate. These
commits do not add a temporary upstream port or a Compose-owned policy surface.

The 12 August 2026 release refresh advances Container through `55275d93a7f1`
and the builder shim through `88332c96705b`. It classifies four release-blocker
repairs as support maintenance: host-architecture kernel selection, isolated
integration service namespaces, the immutable repaired builder-image pin, and
mounted host SSH-agent socket validation. No generic runtime primitive,
temporary upstream port, or rejected Compose-policy disposition changed.

The registry records fork ownership; it does not promote a runtime or Compose
stack pin. The generated Container dependency commits
`d0777a8314b26a2c9311719081ad4da34c097560` and
`ff08b876ab1f87934aa8d2853b921e0ba8590b7b` were inspected as release
maintenance because they only advance exact Containerization revisions.
Release promotion must continue through the exact stack references, normal
signed commits, and the full linked-stack gates without rewriting published
history.

The 13 August 2026 release refresh advances Apple Container through
`d2213f49e6f7` and the Container fork through its signed merge at
`4c527d221601`. The only new Apple change fixes the Kubernetes integration
test's scoped-domain handling; it is upstream history after the merge. The
fork's independently reviewed CoreDNS resolver-loop fix was already present in
the support-maintenance slice, so this refresh changes no classifications and
adds no unreviewed fork-only commit.

The 14 August 2026 release refresh advances Apple Container through
`7d4ffb6cb1ae` and the Container fork through `7fa97f6e5636`. Apple's build
repair is upstream history after the signed merge; the fork retains its stronger
owned and cancelled terminal-resize task while adopting the two missing
`SystemPackage` imports. The three new patch-unique commits harden the semantic
helper's environment snapshot and keep its integration fixture deterministic,
so they are classified as support maintenance.

The final 14 August 2026 release refresh advances Container through
`9aa1803223e8` and Containerization through `f0bc99d26cd2`. Container's exact
Containerization dependency pin and Containerization's recursive
signal-cancellation lock repair are independently reviewed release maintenance;
they add no Compose-owned policy or temporary upstream port.

The 21 August 2026 release refresh advances Apple Container through
`d6de56942004`, Container through `a7ff132653e1`, and Containerization through
`3e078480b85d`. Apple's Kubernetes provisioner split, machine mount hardening,
CLI conformance cleanup, disk-usage identifier-validation tests, and Kata
Containers 3.32.0 debug-kernel default are upstream history after the reviewed
merges. Container's atomic lifecycle discovery commits and Containerization's
lifecycle primitive are classified as generic runtime work. No temporary
upstream port or rejected Compose-policy disposition changed in this refresh.

The 24 August 2026 release refresh advances Container through
`94bb6c4bd1ad`, Containerization through `fefced145304`, and the builder shim
through `e4829be2203b`. The Engine socket guest projection, inbound relay
identity, and socket-relay errno correction are generic runtime primitives.
Dependency repairs and pins, generated-protobuf normalization, and their
review documentation are support maintenance. No temporary upstream port or
rejected Compose-policy disposition changed in this refresh.

The 28 August 2026 release refresh advances Apple Container through
`388d964f3824`, Container through `9a7a6eff882e`, Apple Containerization
through `4294c0f37a01`, Containerization through `4d07c76bafab`, and the
builder shim through `db3e99cc3d19`. Shared-VM isolation and networking,
prewarming, adaptive memory control, bounded startup concurrency, live memory
targets, root-filesystem hotplug, and cached builder-context uploads are
generic runtime primitives. Their tests, documentation, dependency pins, CI,
and release convergence commits are support maintenance. No temporary port or
rejected-policy disposition changed in this refresh.

The 29 August 2026 release refresh advances Apple Container through
`d65874da3655`, Container through `ba9566840b08`, Apple Containerization
through `2faaf9b4aff4`, and Containerization through `e5a92e86bf03`; the
builder shim remains `db3e99cc3d19`. Registry deadline/cancellation repairs,
legacy blob migration, filesystem confinement, malicious digest regression,
CI convergence, and final dependency pins are support maintenance. No generic
primitive, temporary port, or rejected-policy disposition changed in this
refresh.
