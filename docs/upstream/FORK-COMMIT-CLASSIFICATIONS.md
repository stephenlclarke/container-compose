# Fork Commit Classifications

Updated: 12 September 2026

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
| `container` | `55437109add247406b07644f9662f03ded52a5e7` | `780a86b995ac4cb0985db97f38875fdc6e33d16b` | 0 | 844 | 694 |
| `containerization` | `b44e17e1a4c135bc0168e615bf6a8e3798d070c0` | `7e066a3101bc84fa0f7231daf6a03aa9ef62a567` | 0 | 321 | 245 |
| `container-builder-shim` | `5dc4286e5adbeb7dac189b22b7d5aab336942fe2` | `5373d9b4363c6e536dc6401199da269c7045abf9` | 0 | 59 | 46 |
| **Total** | | | **0** | **1224** | **985** |

The graph-ahead count includes merge commits. The classification count excludes
merges and patch-equivalent commits so the registry covers semantic fork work.

## Dispositions

| Classification | Commits | Disposition |
| --- | ---: | --- |
| `support-maintenance` | 729 | Retain independent bug fixes, tests, CI, release engineering, dependency pins, documentation, and review corrections. Split generally useful fixes during FORK-105. |
| `generic-runtime-primitive` | 231 | Retain typed VM, guest, archive, network, process, storage, resource, logging, Engine API, and BuildKit capabilities below Compose. Keep Apple-shaped handoffs and independently reviewable upstream slices. |
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

The final 29 August 2026 correction advances Container through
`b19e8205fc91`. Export now validates persisted root-filesystem metadata before
using a prewarmed block device, preserving corrupt-metadata rejection after
dedicated prewarming. This is support maintenance; no generic primitive,
temporary port, or rejected-policy disposition changed.

The 30 August 2026 release correction advances Container through
`6a094cd6acb5`. Invocation-scoped create and run dependencies let in-process
clients reuse one loaded system configuration and caller-owned control client
without changing the one-command CLI lifetime. This is a generic runtime
primitive; no temporary port or rejected-policy disposition changed.

The 31 August 2026 release refresh advances Apple Container through
`d925dab865cf` and the Container fork through `f87481688f25`. The fork retains
Apple's richer system-status schema and resource reporting while preserving
Engine and builder-shim provenance. The review correction bounds the new image
probe and preserves independently successful resource counts. The earlier
block-backed prewarm eligibility fix and its handoff are also classified as
support maintenance. The final export regression fixture follows the nested
`paths.appRoot` status schema exercised by the release candidate. No generic
primitive, temporary port, or rejected-policy disposition changed in this
refresh.

The 2 September 2026 maintenance refresh advances Apple Container through
`b8ffd38c7344`, Container through `ecf6da9fd029`, Apple Containerization
through `fc9e63846f36`, Containerization through `818f5917819a`, and the
builder shim through `4aff0ea2e7ff`. Known-immediate prewarm avoidance is a
generic runtime optimization. Interrupted prepared cleanup, short-lived exit
preservation, managed clean routing, synchronized dependency pins, workflow
pinning, deterministic `cctl` NBD integration-test scheduling, upstream
stdio/logging sync, reusable-vsock lifecycle corrections, the grpc-go security
update, and their review handoffs are support maintenance. No temporary port
or rejected-policy disposition changed in this refresh.

The 3 September 2026 release refresh advances Apple Container through
`025f57c6c0fe` and Container through `2647090a8af7`. Apple's read-only
`container clean` correction and release-action update are upstream history.
The signed fork handoff is support maintenance. No generic runtime primitive,
temporary port, or rejected-policy disposition changed in this refresh.

The 4 September 2026 maintenance refresh advances Apple Containerization
through `d7fc7c15a257`, Containerization through `7807badff6a8`, and Container
through `83cfab33d0b1`. Apple's `cctl run` ENTRYPOINT/CMD resolution is upstream
history after the reviewed merge. Container's cached gateway-identity pin and
the exact Containerization dependency pin are support maintenance. No generic
runtime primitive, temporary port, or rejected Compose-policy disposition
changed in this refresh.

The final 4 September 2026 release refresh advances Containerization through
`e97e92bf3b7c` and Container through `1f2e4309f4be`. Deterministic serialization
of the VM-backed `cctl run` integration cases and Container's exact dependency
pin are support maintenance. No generic runtime primitive, temporary port, or
rejected Compose-policy disposition changed in this refresh.

The 5 September 2026 maintenance refresh advances Apple Container through
`eee7ad097079`, Container through `a252482bbacb`, Containerization through
`b404e03bb914`, and the builder shim through `287f2ea3276e`. It incorporates
Apple's discarded-task compilation correction while retaining the fork's
stronger managed resize-forwarding lifetime. Runtime fixes cover Kubernetes
address rotation, unreadable image and build inputs, published host paths,
named machine identities, exec and logging cleanup, host-only routing, and
authoritative exit events. Lower-stack fixes cover failed pod starts, bounded
ext4 parsing, registry authentication, terminal restoration, TLS lifecycle,
certificate parsing, dependency security updates, and reusable build tooling.
All newly patch-unique commits are support maintenance; no generic primitive,
temporary port, or rejected Compose-policy disposition changed.

The 7 September 2026 release refresh advances Container through
`40ab92d74a02`, Apple Containerization through `847655d373a2`, and
Containerization through `f9d57ad1c809`. Container's unattended Engine API
keychain dependency pin is support maintenance, while its durable Engine
socket grant is a generic runtime primitive consumed by Compose
`use_api_socket`. Apple's Pi agent support is upstream history after the
reviewed synchronization merge, so it adds no fork-only classification. No
temporary port or rejected Compose-policy disposition changed.

The final 7 September 2026 release refresh advances Container through
`aaacb3ed973f`. Its exact Containerization dependency pin at `09acdc2f1df2`
is support maintenance and adds no new runtime behaviour. No generic runtime
primitive, temporary port, or rejected Compose-policy disposition changed.

The corrected-builder refresh advances Container through `d8ccda0fd6f3` and
the builder shim through `f99e66b89402`. Container's immutable builder image
pin at `25399784a692` and the builder shim's module-derived Go toolchain fix at
`8538b2e7931f` are support maintenance. They make the matched build
reproducible without adding runtime behaviour or changing any temporary port,
generic primitive, or rejected Compose-policy disposition.

The machine-runtime release repair advances Container through
`24c4726d1048`. Numeric user resolution at `8372b65b66f1` and serialized
completed-exec cleanup at `7601ceca01d4` are independently reviewed bug fixes,
so both are support maintenance. They restore existing runtime behaviour
without adding a generic primitive or changing any temporary port or rejected
Compose-policy disposition.

The 8 September 2026 process-deletion recovery advances Containerization
through `9e0626e1171c` and Container through `0eb4a7e9df9b`. The runtime fix
redials an available VM only when an exited process retained an already-stopped
gRPC client; the Container change pins that reviewed correction. Both are
support maintenance and add no Compose policy or new public runtime primitive.

The 8 September 2026 release-gate correction advances Container through
`7ed777a17155` and classifies two reviewed support-maintenance commits. The
runtime change makes `system stop` clean an unhealthy Kubernetes API server
and every namespace service; its focused regression proves that cleanup and
error propagation. The companion Kubernetes test proves that a retained
cluster restarts on its configured address without preserving the obsolete
address-rotation expectation. Neither commit adds a fork-only capability or
temporary upstream port.

The 9 September 2026 release refresh advances Apple Container through
`9a8917ca2da5`, Container through `7da98fd3c8e0`, Apple Containerization
through `9eacc197d7c3`, Containerization through `28ad7c77a2a5`, Apple builder
shim through `5dc4286e5adb`, and the builder shim through `5373d9b4363c`.
Apple's Kubernetes guide, CZ 0.45.0 update, OCI-layout hardening, confined
rootfs copy/stat handling, and Unix-socket length fix are upstream history.
The ten new patch-unique commits cover dependency security and exact pins,
deterministic protobuf and image publishing, retained VSOCK and VM-init
authority, and strict upstream-aware signature verification. All are support
maintenance; no generic primitive, temporary upstream port, or rejected
Compose-policy disposition changed.

The subsequent 0.14.3 release-gate correction advances Containerization to
`5372b36a691c` and Container to `a702f22b0e76`. Signed Containerization commit
`79d5eb1ec231` restores the fork's guest-device `stat` protocol adapter while
retaining Apple's confined implementation; signed Container commit
`8dc1d66f4f5c` advances the exact dependency pin. Both are support maintenance.

Apple's subsequent v1.0 compatibility-policy update is preserved through the
signed Container merge at `36db202b7a42` and reviewed fork merge
`cc424d2be1cd`. It adds no new fork-only semantic commit, so the classification
count is unchanged.

The 10 September 2026 refresh advances Apple Containerization through
`a7221ab17f3`, Containerization through `bd8130fea851`, and Container through
`e653616e62ab`. Apple's token-response serialization fix is preserved, while
the merge resolution keeps the fork's typed registry-token cache and accepts
both fractional and whole-second RFC 3339 issue times. Container commit
`e891c12796f1` advances the exact dependency pin and is classified as support
maintenance; the Containerization merge adds no patch-unique non-merge commit.

The 12 September 2026 release refresh advances Apple Container through
`55437109add2`, Apple Containerization through `b44e17e1a4c1`, the reviewed
Container merge through `780a86b995ac`, and Containerization through
`7e066a3101bc`. Apple fixes localhost-DNS egress, closes an abandoned forwarding
backend, removes a warning, and corrects Kubernetes documentation; its
Containerization change is documentation-only. The 13 newly classified
fork-only commits cover dependency identity and exact pins, OCI platform-aware
image inspection, bounded log-record responses, and the reviewed Packet Filter
corrections. The PF design preserves Apple's egress-safe child-anchor reload,
normalizes legacy directives, rejects ambiguous configuration, and independently
verifies an active redirect attachment point before changing either file. All 13
commits are support maintenance; no generic runtime primitive, temporary port,
or rejected Compose-policy disposition changed.
