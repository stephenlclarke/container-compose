# Current Apple Upstream Review

This is the current disposition of Apple work that affects the five-repository container stack. Re-check GitHub before changing an Apple-backed component because issue, review, and merge state can change independently.

Apple pull-request state was queried 29 July 2026. Fetched Apple and
supported-fork baselines, fork classifications, and Compose development pins
were refreshed 30 July 2026 without claiming a fresh query of every Apple pull
request.

## Scope

- `apple/container`
- `apple/containerization`
- `apple/container-builder-shim`

## Fetched Main Baselines

The table compares each fetched Apple `main` with the currently published
fork `main`. The left/right counts are from `git rev-list
--left-right --count <apple-main>...<fork-main>`:

| Repository | Apple `main` | Fork `main` | Apple-only | Fork-only |
| --- | --- | --- | ---: | ---: |
| `container` | `6e65319fe476ffe8db8ddaf828a537ed36fe2859` | `8657c4b8685865c8889b0171d953342fc9f427a7` | 0 | 338 |
| `containerization` | `ff44a5b683c80fceab875dba8a20ed24d7648c07` | `971fc7e5e27467ebd6227e1ae54f3e5c23de87b4` | 0 | 135 |
| `container-builder-shim` | `267b5ab98e1d7db7d98af98bdc90578bf5fd3192` | `61832d4ca91715180a84dec0eab091170174c43c` | 0 | 34 |

The supported default branches contain their complete fetched Apple histories.
Their 440 patch-unique non-merge commits are classified in
[Fork Commit Classifications](FORK-COMMIT-CLASSIFICATIONS.md): 299 in
`container`, 112 in `containerization`, and 29 in
`container-builder-shim`. The fork-only counts above include merge commits and
are not a count of changes ready for Apple.

Compose currently pins the separately validated development heads
`container` `88460ab2ab0ca2f3fa9f91b2911b3b77647596c1`,
`containerization` `d7377b962af724f8d7c2b640f3ab12184d33f1af`,
and `container-builder-shim`
`61832d4ca91715180a84dec0eab091170174c43c`. The Container pin contains the
current Apple head. The Containerization pin predates merged Apple PR #813 by
one Apple commit and retains an older patch-unique vminitd correction, so it
requires explicit reconciliation rather than an assumed duplicate removal.

## Submitted Stephen-Authored Apple Pull Requests

### Open

All ten open pull requests are ready rather than drafts, mergeable, and
awaiting Apple maintainer review.

| Pull request | Published head | Current state and purpose |
| --- | --- | --- |
| [apple/container#2036](https://github.com/apple/container/pull/2036) | `f2f248fbb80092d47945e30eaf0e0b79ace9ff16` | Review required. Close the path-specific directory watcher descriptor after failed startup; deterministic repeated leak tests and the full 590-test stock suite pass locally. Apple Actions are `action_required`; no hosted job has run. |
| [apple/container#2035](https://github.com/apple/container/pull/2035) | `a8d3b5c87e468a3641ef075c3fce686e206817ad` | Review required. Preserve unloadable bundles, restore state before insertion, and atomically replace root-filesystem metadata; focused persistence regressions and the full stock suite pass locally. Apple Actions are `action_required`; no hosted job has run. |
| [apple/container#2031](https://github.com/apple/container/pull/2031) | `58b07fcaa6f09426adc6cd792732c855496ed80f` | Review required. Preserve active and infrastructure image aliases. Apple Actions are `action_required`; no hosted job has run. |
| [apple/container#1965](https://github.com/apple/container/pull/1965) | `618d28197a20baf643dbdc87272e9f768f57f888` | Review required. Honour generic XPC request timeouts. Apple Actions are `action_required`; no hosted job has run. |
| [apple/container#1935](https://github.com/apple/container/pull/1935) | `f4f908606d4a7693f9bfc958593f7671b35caa0f` | Review required. Keep root help responsive for [apple/container#1459](https://github.com/apple/container/issues/1459); stacked on the preferred cancellation work in [apple/container#1862](https://github.com/apple/container/pull/1862). Apple Actions are `action_required`; no hosted job has run. |
| [apple/container#1934](https://github.com/apple/container/pull/1934) | `d5d73ef1a95ca9f78ffa287b7c2e5204bfd9d569` | Review required. Preserve the complete `unspecified` version placeholder. Apple Actions are `action_required`; no hosted job has run. |
| [apple/containerization#823](https://github.com/apple/containerization/pull/823) | `3ed10bf1a0dda802cb46c1f0b55934c55a4bd395` | Review required. Prevent deferred directory metadata from following an intermediate symlink or applying to a removed and recreated directory; all 579 stock tests and `make check` pass locally. Apple Actions are `action_required`; no hosted job has run. |
| [apple/containerization#821](https://github.com/apple/containerization/pull/821) | `726e1ffdceada5cc62d32c8fc939aef30220e6ff` | Review required. Restore permissions after ownership so `fchown` cannot clear set-ID bits. This pull request intentionally depends on #820. Apple Actions are `action_required`; no hosted job has run. |
| [apple/containerization#820](https://github.com/apple/containerization/pull/820) | `6e32963617b3ed8f4b63432dbcf834f94807342b` | Review required. Preserve sticky, set-user-ID, and set-group-ID archive permission bits. Apple Actions are `action_required`; no hosted job has run. |
| [apple/containerization#799](https://github.com/apple/containerization/pull/799) | `9c5b9ee19796dc13f0d7d1b0687d780f0db04e29` | Review required with hosted build, signature, and Linux compile checks green. Missing copy sources fail promptly and no longer block later lifecycle operations. |

No Stephen-authored pull request has been submitted to
`apple/container-builder-shim`.

### Merged or closed

| Pull request | Final state | Disposition |
| --- | --- | --- |
| [apple/containerization#813](https://github.com/apple/containerization/pull/813) | Merged 29 July 2026 | Apple now redacts OCI environment values through descriptions. The older fork vminitd call-site correction remains patch-unique and must be reconciled explicitly rather than retained as an assumed duplicate. |
| [apple/containerization#798](https://github.com/apple/containerization/pull/798) | Merged 15 July 2026 | The CloudHypervisor SwiftPM exclusion is present in current Apple `main`; no fork-only replacement remains necessary. |
| [apple/container#1933](https://github.com/apple/container/pull/1933) | Closed 22 July 2026 without merge | Superseded by merged production handler work in `apple/container#1981` and `apple/containerization#808`. |
| [apple/container#1838](https://github.com/apple/container/pull/1838) | Closed 27 June 2026 without merge | Superseded by open replacement #1935. |
| [apple/container#1831](https://github.com/apple/container/pull/1831) | Closed 27 June 2026 without merge | Superseded by open replacement #1934. |
| [apple/container#1765](https://github.com/apple/container/pull/1765) | Closed 27 June 2026 without merge | The broad Docker-compatible timestamp parser was not accepted upstream; Docker timestamp parsing remains Compose-owned. |
| [apple/container#1764](https://github.com/apple/container/pull/1764) | Closed 27 June 2026 without merge | The broader log retrieval proposal was not merged; generic log retrieval still needs smaller Apple-shaped primitives. |
| [apple/container#1758](https://github.com/apple/container/pull/1758) | Closed 27 June 2026 without merge | Superseded first by #1933 and then by Apple's merged production handler changes. |

[PR-ARCHIVE.json](PR-ARCHIVE.json) currently retains immutable snapshots for Apple PRs #1933, #1934, #1935, #1965, containerization PRs #798 and #799, and third-party builder-shim PR #87. It does not yet archive the current heads of `apple/container` PRs #730, #1508, #1630, #1660, #1708, #1735, #1862, #1926, #1947, #1997, #2031, #2035, or #2036, or `apple/containerization` PRs #753, #792, #812, #820, #821, or #823. The code archive is therefore incomplete until immutable Stephen-owned refs for those heads are added and verified.

## Handoff Inventory

[HANDOFF-REGISTRY.json](HANDOFF-REGISTRY.json) is now the source of truth. Its generated [reader view](HANDOFF-REGISTRY.md) contains 360 capability or pull-request rows, 616 immutable document snapshots, 473 unique referenced commits, and 14 current supporting documents:

- `apple-container-builder-shim/PR-87.md`
- `apple-container/PR-1926.md`
- `apple-container/PR-1934.md`
- `apple-container/PR-1935.md`
- `apple-container/PR-1997.md`
- `apple-containerization/PR-799.md`
- `container-compose/ISSUE-173.md`
- `container-compose/PR-173.md`
- `container-compose/ISSUE-container-runtime-validation-reliability.md`
- `container-compose/PR-container-runtime-validation-reliability.md`
- `container-compose/ISSUE-network-mode-bridge.md`
- `container-compose/PR-network-mode-bridge.md`
- `container-compose/ISSUE-package-compatibility-preflight-drain.md`
- `container-compose/PR-package-compatibility-preflight-drain.md`

The registry records 301 retired entries, 23 unsubmitted candidates, ten open Stephen-authored submissions, 16 tracked third-party pull requests, seven merged pull requests, and three closed pull requests. Submitted PRs #1965, #2031, #2035, #2036, #820, #821, and #823 are first-class registry rows without separate Markdown files. The two stock-shaped PR #33 follow-ups and the Apple pull requests that moved the fetched main branches are also first-class rows.

An unsubmitted registry row is not automatically submission-ready. Before
submission, rebase the smallest independent change on current stock Apple
`main`, rerun stock validation, fill the current Apple issue and pull-request
templates, and keep Stephen-only compatibility behaviour out of the patch.

## PR #33 Stock-Apple Review

[stephenlclarke/container#33](https://github.com/stephenlclarke/container/pull/33)
is an open fork PR at
`7ffac9dcf059bd62da87cebe40d20ce05742238c`. Its two defects both exist on
stock `apple/container:main` at
`6e65319fe476ffe8db8ddaf828a537ed36fe2859`, but the fork PR is not directly
upstreamable:

- Stock `XPCMessage.set` still calls raw
  `close(value.fileDescriptor)` and `close(fh.fileDescriptor)` after creating
  XPC objects. That closes the descriptor without marking the owning
  Foundation `FileHandle` closed, so a later explicit close can close an
  unrelated descriptor that reused the same integer. The production
  correction to call `FileHandle.close()` is directly relevant to stock.
- Stock `ProcessIO` still performs a potentially blocking guest-pipe write
  inside Foundation's stdin `readabilityHandler`, while stdout and stderr use
  Foundation readability handlers too. The full-duplex deadlock mechanism
  therefore also exists on stock.
- The ProcessIO commit conflicts when applied to stock because the fork adds
  detach-key matching and attached-process handling that Apple `main` does
  not have. The XPC regression also depends on the fork's
  `ContainerXPCTests` target and prior variable-descriptor-array test
  infrastructure, neither of which exists on stock.

The supported development branch contains both corrections. The XPC ownership
case uses the stronger independent fix at
`6320cf8203a8544bb049ef030f7be569748dc667`; the ProcessIO input pump was
ported as `ae66e3e2e69fee3c26fa84a402df79ccc45ca9bc`. Focused ProcessIO testing,
`make check`, and the full 1,244-test Container suite pass at that published
head. These local corrections do not change the Apple submission state.

The upstream disposition is to split PR #33 into two unsubmitted,
stock-shaped proposals: one focused XPC `FileHandle` ownership correction
with a stock-compatible descriptor-reuse regression, and one ProcessIO input
pump/backpressure correction adapted to Apple's simpler API. No Apple issue or
pull request has been filed for either slice.

## Unsubmitted Review Candidates

| Repository | Current purpose |
| --- | --- |
| `apple/container` | [Generic IPv6 network disablement](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-network-ipv6-disablement.md) adds a typed macOS vmnet NAT66 and router-advertisement control while retaining enabled compatibility by default. |
| `apple/container-builder-shim` | [Build-context source-read errors](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container-builder-shim/PR-build-context-source-read-errors.md) fail explicitly instead of sending empty file content. |
| `apple/container-builder-shim` | [Build-context cache integrity](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container-builder-shim/PR-build-context-cache-integrity.md) verifies archives, atomically publishes cache trees, and keeps synthetic Dockerfiles request-local. |
| `apple/container` | [Fork CI validation](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-fork-ci-validation.md) runs formatting, generated-source checks, builds, and unit tests in contributor forks while retaining official guest integration. |
| `apple/container` | [Live filesystem snapshot export](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-live-export-snapshot.md) adds a generic `export --live` primitive for a running container, based on the direction in [apple/container#1630](https://github.com/apple/container/pull/1630). |
| `apple/container` | [Additional guest interface addresses](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-additional-interface-addresses.md) carry generic typed CIDRs through runtime attachment strategies. |
| `apple/container` | [Requested primary network addresses](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-requested-primary-network-addresses.md) reserve generic typed IPv4 and IPv6 attachment addresses with collision checks. |
| `apple/container` | [IPv4 network gateway configuration](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-network-ipam-gateway.md) carries a validated generic gateway through persisted network configuration, helper startup, vmnet setup, and attachment allocation. |
| `apple/container` | [IPv4 allocation-range configuration](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-network-ipam-allocation-range.md) carries a generic dynamic-allocation CIDR through persisted network configuration, helper startup, and attachment allocation. |
| `apple/container` | [IPv4 network address reservations](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-network-ipv4-reserved-addresses.md) carry validated generic reservations through persisted network configuration, helper startup, and attachment allocation. |
| `apple/container` | [Numeric supplemental process groups](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-supplemental-groups.md) expose the runtime's existing typed GID support through the generic process CLI surface. |
| `apple/container` | [Owned regular-file bind snapshots](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-file-mount-ownership.md) expose optional UID/GID mapping without mutating the host source. |
| `apple/container` | [Compiled build glob caching](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-build-glob-cache.md) compiles each Docker ignore pattern once per context while retaining the existing Swift regex semantics. |
| `apple/container` | [Hashed build-context membership](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-build-context-membership.md) uses the existing `Set<DirEntry>` contract instead of scanning it linearly for each archive candidate. |
| `apple/container` | [Concurrent stats sampling](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-stats-concurrent-sampling.md) fans out independent runtime samples while preserving list order and failure semantics. |
| `apple/container` | [Disk-usage lock scope](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-disk-usage-lock-scope.md) snapshots metadata under service locks and traverses resource trees on detached utility tasks. |
| `apple/containerization` | [Fork CI validation](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-containerization/PR-fork-ci-validation.md) runs supported checks in contributor forks while retaining official guest image and integration work. |
| `apple/containerization` | [Additional guest interface addresses](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-containerization/PR-additional-interface-addresses.md) configure generic supplemental IPv4/IPv6 CIDRs before link-up. |
| `apple/containerization` | [Owned regular-file bind snapshots](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-containerization/PR-file-mount-ownership.md) create private guest copies only when ownership metadata is requested. |
| `apple/containerization` | [Cgroup formatter catch spacing](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-containerization/PR-cgroup-catch-format.md) restores the exact spelling required by the strict Swift formatter without changing runtime behavior. |
| `apple/containerization` | [vmnet integration exclusivity](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-containerization/PR-vmnet-integration-exclusivity.md) serializes only host-networking VM tests so release validation remains deterministic. |

These candidates remain unsubmitted. Their source commits and tests were
reviewed in the fork, but each still requires a fresh stock-Apple rebase and
validation before submission.

## Overlapping Upstream Work

| Pull request | Local disposition |
| --- | --- |
| [apple/container#1862](https://github.com/apple/container/pull/1862) | Preferred XPC cancellation implementation. The supported stack adapts its cancellation and unknown-route behavior in `c8b70994199f68e0f5ee0e0c7eecacbee84ffea7` without regressing the fork's stronger timeout error code and direct resume-once path. Deterministic pre-storage cancellation, caller cancellation, delayed timeout reply, delayed cancellation reply, client reuse, and unknown-route tests pass. The unchanged Apple commit remains the base of `apple/container#1935`; drop both local representations when #1862 lands. |
| [apple/container#1926](https://github.com/apple/container/pull/1926) | Its attached-exec disconnect cleanup is represented in `stephenlclarke/container`; its separate stop-timeout path still needs single-owner cleanup review. |
| [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87) | Its `.dockerignore` re-included-parent fix is represented by standalone commit `2778407`; the fork retains its staged-Dockerfile safeguard until the upstream shape lands. |
| [apple/container#1735](https://github.com/apple/container/pull/1735) | Preferred daemon entry-point ID validation. Imported as standalone commit `16ecfd5`; the broader residual bundle-path and volume-disk-usage hardening is tracked in [PR-container-storage-path-validation.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-container-storage-path-validation.md) and must follow this PR rather than compete with it. |
| [apple/container#1630](https://github.com/apple/container/pull/1630) | The local live-export handoff is a generic snapshot primitive based on this direction. It uses a unique temporary snapshot and serializes the freeze/copy/thaw lifecycle; it deliberately does not add Docker-shaped `container commit` behavior from [apple/container#1762](https://github.com/apple/container/pull/1762). |

## Tracked Third-Party Apple Pull Requests

| Pull request | Local disposition |
| --- | --- |
| [apple/container#2006](https://github.com/apple/container/pull/2006) | Merged 27 July 2026 as `13e976f88e7da4ff71559b7e6e4e763ff38364ce`, closing [apple/container#2003](https://github.com/apple/container/issues/2003). The supported fork contains the merge through its current Apple baseline; no fork-only replacement is needed. |
| [apple/container#1818](https://github.com/apple/container/pull/1818) | Closed 20 July 2026 without merge. The ordered-journaling source change remains a fork-only standalone commit at `6e525cc`. |
| [apple/container#1708](https://github.com/apple/container/pull/1708) | Open and approved; GitHub currently reports mergeability as unknown. Already represented by the machine-configuration documentation in `3bb6864`. |
| [apple/container#1660](https://github.com/apple/container/pull/1660) | Open and approved; GitHub currently reports mergeability as unknown. Already represented by the application-root backup exclusion in `3bb6864`. |
| [apple/container#1508](https://github.com/apple/container/pull/1508) | Open, mergeable, and awaiting review. It is not copied because the local SSH forwarding implementation supports default, explicit, and multiple named sockets. Reconcile with upstream if this PR changes or lands. |
| [apple/container#730](https://github.com/apple/container/pull/730) | Open and approved. Already represented in `3bb6864`, plus the parse-entry correction required by the fork's `@main` wrapper. |
| [apple/containerization#753](https://github.com/apple/containerization/pull/753) | Open and approved. Already represented by `8de8a10`, including default client ID, caller override, and request-header tests. |
| [apple/container#1889](https://github.com/apple/container/pull/1889) | Merged 23 July 2026 and present in the current Apple baseline. The earlier fork port at `0fe7833` is now retained only as ancestry. |
| [apple/container#1997](https://github.com/apple/container/pull/1997) | Open, mergeable, and awaiting review. Its content-identical signal-name correction is represented by `bb2438c`. |
| [apple/container#2000](https://github.com/apple/container/pull/2000) | Closed 28 July 2026 without merge. The fork's existing backward-read tests continue to cover the reported behaviour. |
| [apple/containerization#792](https://github.com/apple/containerization/pull/792) | Open, mergeable, and awaiting review. Its fresh-session registry retry behaviour is represented by `d388a15` and `c8043bb`. |
| [apple/containerization#813](https://github.com/apple/containerization/pull/813) | Merged 29 July 2026 as `ff44a5b683c80fceab875dba8a20ed24d7648c07`. The older local vminitd correction remains patch-unique and requires explicit reconciliation with Apple's OCI-level redaction. |
| [apple/containerization#812](https://github.com/apple/containerization/pull/812) | Open, mergeable, blocked draft at `570a56f74bf79aa3fa383e708d4741043c1e4f6f`. It proposes direct `FileHandle` copy streams. Do not import it before API, cancellation, backpressure, path-safety, and archive-metadata review. |
| [apple/container#1947](https://github.com/apple/container/pull/1947) | Open, mergeable, blocked draft at `7199840b57504963e0f76370a72dfcd74d927eb9`. It exposes the direct-stream container CLI surface on top of #812 and is not represented in the supported fork. |
| [apple/container-builder-shim#89](https://github.com/apple/container-builder-shim/pull/89) and [apple/container#2040](https://github.com/apple/container/pull/2040) | Open, mergeable, and awaiting review at `134c7381dc3b1a06afe2d2025fab30c597f26bdd` and `f27d3e37cf7c6470b65c8e4a6f6af36fa0b20b68`. The meta-`ARG` implementation is technically sound, but equivalent pre-`FROM` default and explicit override resolution is already present in the supported builder fork. Do not duplicate the resolver; retain the upstream integration test as convergence evidence. |

## Confirmed Local Impact

| Upstream report | Current resolution |
| --- | --- |
| [apple/containerization#518](https://github.com/apple/containerization/issues/518) | Exec debug logging no longer serializes environment-backed secrets; fixed in `f17ec69`. |
| [apple/container#1917](https://github.com/apple/container/issues/1917) | Generated resolver files no longer pollute the macOS global search list; fixed in `stephenlclarke/container` `160035f`. |
| [apple/container#1888](https://github.com/apple/container/issues/1888) | The focused stderr correction from merged [apple/container#1889](https://github.com/apple/container/pull/1889) is in the current Apple baseline. The earlier fork port at `0fe7833` is now retained only as ancestry. |
| [apple/container#1672](https://github.com/apple/container/issues/1672) | [apple/container#1717](https://github.com/apple/container/pull/1717) is ported as `7329f12`. |
| [apple/container#1767](https://github.com/apple/container/issues/1767) | [apple/container#1818](https://github.com/apple/container/pull/1818) closed without merge; the ordered-journaling correction remains fork-only at `6e525cc`. |
| [apple/container#1757](https://github.com/apple/container/issues/1757) | Launch failures and application-root mismatches are handled in `stephenlclarke/container` `6ac1253`. |
| [apple/containerization#790](https://github.com/apple/containerization/issues/790) and [apple/container#1895](https://github.com/apple/container/issues/1895) | Fresh-session registry retry behavior from [apple/containerization#792](https://github.com/apple/containerization/pull/792) is represented by `d388a15` and `c8043bb`. |
| [apple/container#1937](https://github.com/apple/container/issues/1937) | Directory bind mounts containing hardlinks can intermittently fail with `EACCES` inside the guest. The fork carries non-root hard-link directory bind-mount regression coverage in `stephenlclarke/container` `e0034f4`, but that controlled coverage does not claim the intermittent upstream race is resolved. The single-file hardlink fix from [apple/containerization#665](https://github.com/apple/containerization/pull/665) is already present; `container-compose` must not paper over the directory bind behavior with a copy or snapshot workaround that would break live mounts. |
| [apple/container#1977](https://github.com/apple/container/issues/1977) | Labels now split only at their first `=` in `stephenlclarke/container` `47c13a8`; the Apple-shaped handoff and Compose v2 parity follow-through are recorded in [PR-label-value-equals.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-label-value-equals.md) and [PR-label-value-equals.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/PR-label-value-equals.md). |
| [apple/container#1969](https://github.com/apple/container/issues/1969) | `container copy` now splits a container path reference only at its first `:` in `stephenlclarke/container` `f03ae57`, so legal colons in guest paths are retained. The generic runtime and Compose dependency handoffs are recorded in [PR-copy-path-colon.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-copy-path-colon.md) and [PR-copy-path-colon.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/PR-copy-path-colon.md). |
| Isolated runtime startup | A stale same-label launchd service no longer binds a new `--app-root` to an older XPC helper. The generic macOS correction is `stephenlclarke/container` `7272c40`; its issue/PR handoff is [ISSUE-launchd-service-ownership.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/ISSUE-launchd-service-ownership.md) and [PR-launchd-service-ownership.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-launchd-service-ownership.md). |
| Compose image-volume subpath teardown | Generic `LinuxContainer` cleanup now unmounts staged subpath binds and their backing volumes so the guest root is removable without `EBUSY`; fixed in `stephenlclarke/containerization` `93d7710` and documented by [ISSUE-staged-subpath-mount-cleanup.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-containerization/ISSUE-staged-subpath-mount-cleanup.md) and [PR-staged-subpath-mount-cleanup.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-containerization/PR-staged-subpath-mount-cleanup.md). |
| Compose completed dependency state | A one-shot dependency reported as `exited` now satisfies `service_completed_successfully` when its stored exit code is zero, matching the existing `stopped` handling. The Compose-only correction is `74d02bb` and is documented by [ISSUE-completed-dependency-exited-status.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/ISSUE-completed-dependency-exited-status.md) and [PR-completed-dependency-exited-status.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/PR-completed-dependency-exited-status.md). |
| Compose unconfigured image-volume provider | Library-only image-volume planning no longer interprets a missing runtime provider as an image with no declared volumes. The Compose-only correction is `5d532790`, with full provider-contract coverage and handoffs in [ISSUE-unconfigured-runtime-image-volume-provider.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/ISSUE-unconfigured-runtime-image-volume-provider.md) and [PR-unconfigured-runtime-image-volume-provider.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/PR-unconfigured-runtime-image-volume-provider.md). |
| Concurrent Compose image builds | Generic BuildKit startup now serializes only the macOS inspect/create/bootstrap lifecycle for each builder, so concurrent Compose builds reuse the `buildkit` singleton instead of receiving `container already exists`. The correction is `stephenlclarke/container` `7be83a2`; its issue/PR handoff is [ISSUE-builder-startup-race.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/ISSUE-builder-startup-race.md) and [PR-builder-startup-race.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-builder-startup-race.md). |
| Quiet machine-list integration | The generic `machine ls -q` test no longer assumes exclusive ownership of the runtime-wide machine list. It verifies that its own machine is listed without a table header, while retaining other legitimate entries; fixed in `stephenlclarke/container` `e36445b` and documented by [ISSUE-machine-list-quiet-test-isolation.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/ISSUE-machine-list-quiet-test-isolation.md) and [PR-machine-list-quiet-test-isolation.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-machine-list-quiet-test-isolation.md). |
| Compose follow-log XPC decoding | A one-descriptor `container logs --follow` reply no longer makes the generic macOS XPC client duplicate an out-of-range second descriptor and trap. The correction is `stephenlclarke/container` `a8f6cae`; its issue/PR handoff is [ISSUE-xpc-variable-descriptor-arrays.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/ISSUE-xpc-variable-descriptor-arrays.md) and [PR-xpc-variable-descriptor-arrays.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/PR-xpc-variable-descriptor-arrays.md). |
| Compose child-process cancellation | Cancelling a Compose task now owns and terminates its complete host process group across captured, prompt-inheriting, inherited, and explicit-stdin modes. The Compose-only correction is `044d836d`, reusing `ContainerizationOS.Command` for group creation with atomically latched and bounded TERM-to-KILL escalation, ownership-checked and `SIGTTOU`-safe terminal handoff/restoration, independent background job-control group tracking, `WUNTRACED` stop relay through the parent shell job, per-pipe broken-pipe handling, and handoffs in [ISSUE-process-runner-task-cancellation.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/ISSUE-process-runner-task-cancellation.md) and [PR-process-runner-task-cancellation.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/PR-process-runner-task-cancellation.md). Exit restores the retained parent group only while the child still owns the terminal, including after an `fg` resume. No Apple runtime fork change is required. |
| Compose package preflight output | Runtime package and service checks now reuse the asynchronous Compose process runner, so stdout and stderr drain while each child runs and cancellation owns the exact process group. Compose-only corrections `81d32eb2`, `96ac7830`, `045d020c`, `9db8f060`, `e0ad1dfe`, `4bf2eac6`, `3ed87228`, `fbe0ce05`, `b65d18a6`, `62a40d48`, `b07e9da8`, and `5b6f4880` bound retained output at the process-drain boundary and displayed failures at a 64 KiB absolute raw-stream boundary without splitting valid UTF-8 scalars even after leading-whitespace trimming, preserve exact omitted source-byte counts for malformed output and whitespace-only retained prefixes, report content that starts beyond a whitespace-consumed display budget, scan large diagnostics without a proportional per-byte object model, retain stderr priority, retain public `CommandResult` equality and unbounded runner semantics, preserve `CancellationError` from both compatibility awaits, install signal handling before child-task creation, synchronously register delivered signal handlers, drain dispatch-source cancellation, and await those handlers before accepting the proxied result. This guarantees the preflight group is cancelled and reaped before a host signal becomes the CLI shell status. Test correction `592266a7` exercises a 16 MiB packaged-CLI failure below a 320 MiB maximum resident-memory ceiling. The large-output, bounded-capture, diagnostic, memory, signal, cancellation, and child-reaping evidence is recorded in [ISSUE-package-compatibility-preflight-drain.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/ISSUE-package-compatibility-preflight-drain.md) and [PR-package-compatibility-preflight-drain.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/PR-package-compatibility-preflight-drain.md). No Apple runtime fork change is required. |
| Compose `cp -` archive metadata | The supported stack now streams caller-owned archives through `stephenlclarke/containerization` `52386838456a431d24bed6c38a9e84fb0ad28997`, `stephenlclarke/container` `f5e25b12ed074e7e5fb09933d86a27652034f3e5`, and the matching Compose branch. The automated Docker Compose v5.3.1 fixture requires content, ownership, mode, timestamp, symlink, hard-link, sparse allocation, long-path, and large-file parity and records operation timings. Stock Apple still lacks this reviewed API; third-party drafts [apple/containerization#812](https://github.com/apple/containerization/pull/812) and [apple/container#1947](https://github.com/apple/container/pull/1947) remain tracked rather than imported verbatim. |
| Compose process-start observation | The exact-main SonarCloud analysis for child-process cancellation identified one undocumented no-op observer and two nested launch-observer closures. Compose-only correction `7939874a` names the private callback contract, invokes it through one helper outside the asynchronous continuation bodies, and explains the production no-op without changing launch or cancellation behavior. Follow-up merge `617c2036` passed exact-main analysis `fe1e52b4-9674-4da6-90f8-ce4b0155909d` with zero unresolved issues or hotspots. See [ISSUE-process-start-observer-maintainability.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/ISSUE-process-start-observer-maintainability.md) and [PR-process-start-observer-maintainability.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/PR-process-start-observer-maintainability.md). |
| Current VHS runtime startup | The self-hosted Current release runner now requires the global Container launchd namespace to remain absent before recording, repeats that guard after a transport-only reset, and visibly types one bounded retry of the exact packaged-runtime start. This is Compose release-layer recovery for an XPC interruption after a long retained-runtime stop; it changes no Apple runtime source and introduces no Replay, Marker, or transcript path. Four signed commits merged as `4b4a4cff`; exact-main CI, CodeQL, and SonarCloud analysis `b31c11e9-089a-4c1e-b3c6-44967b74ad79` passed with zero unresolved issues or hotspots. Current run `30231378606` published matched checksummed and SLSA-attested archives plus a 303.92-second GIF whose commands and real output are live, with 16 `Type`, 16 `Enter`, 14 `Wait`, zero Replay, and zero Marker instructions. See [ISSUE-current-vhs-start-recovery.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/ISSUE-current-vhs-start-recovery.md) and [PR-current-vhs-start-recovery.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/PR-current-vhs-start-recovery.md). |
| Current full-dispatch authority | A docs-only main merge requires explicit full-validation CI to establish runtime, coverage, and SonarCloud authority. Current's controller accepted that exact successful `workflow_dispatch`, but its independent package-time guard pre-filtered to push events and rejected the same run after cache restoration. Compose-only correction `c8524d36` accepts successful exact-main CI from the existing trusted `push` or `workflow_dispatch` set and continues to exclude all other events. See [ISSUE-current-dispatch-release-authority.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/ISSUE-current-dispatch-release-authority.md) and [PR-current-dispatch-release-authority.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/PR-current-dispatch-release-authority.md). |
| Current dependency cache overhead | Current run `30235634675` spent 10 minutes restoring a 2.13 GB SwiftPM cache and 19 minutes 19 seconds attempting a 1.62 GB Go cache restore, versus 2 minutes 25 seconds and 2 minutes 17 seconds for the respective runtime and Compose builds. Compose-only correction `6cae9a84` removes the release SwiftPM cache and disables release `setup-go` caching while retaining all validation-workflow caches. See [ISSUE-release-dependency-cache-overhead.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/ISSUE-release-dependency-cache-overhead.md) and [PR-release-dependency-cache-overhead.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/container-compose/PR-release-dependency-cache-overhead.md). |
| [apple/container#1941](https://github.com/apple/container/issues/1941) | The supported fork ports the content-identical signal-name correction from [apple/container#1997](https://github.com/apple/container/pull/1997) in `bb2438c`, with regression coverage in `26cc778` and handoff details in [PR-1997.md](apple-container/PR-1997.md). Drop the port when Apple merges an equivalent fix. |
| [apple/container#1967](https://github.com/apple/container/issues/1967) | [apple/container#2000](https://github.com/apple/container/pull/2000) closed 28 July 2026 without merge. The supported `LogFileOutput` already retains complete records across backward-read chunks; explicit 3 KB and multi-record tests in `26cc778` cover the reported behaviour. |
| [apple/container#2009](https://github.com/apple/container/issues/2009) | The supported init-process reattach path writes persistent sinks first and removes failed clients through `AttachableOutput`; `26cc778` proves later persistent writes continue. Apple main still needs its own reviewed fix. |
| [apple/containerization#798](https://github.com/apple/containerization/pull/798) | Merged upstream. Its SwiftPM manifest correction is included in the current Apple baseline, so it no longer needs fork-side review or a local port. |
| [apple/container#2021](https://github.com/apple/container/issues/2021) | Host disk-space retention after deleting guest files is owned by the macOS Virtualization.framework virtio-fs implementation and is released when the container stops. The supported stack must not add a divergent copy, remount, or guest-filesystem workaround for an Apple OS primitive. Track the upstream platform resolution. |
| [apple/container#2022](https://github.com/apple/container/issues/2022) | The reported long-line `logs -n` correctness case passes on the installed supported runtime with a 2,001-byte first record and exact final three records. The four reported hot-path inefficiencies reproduce in the fork and are corrected as independent signed commits: glob cache `abab498f` plus Unicode-semantics correction `4436afe`, hashed context membership `41e31f7`, concurrent stats `600fde2`, and off-lock disk sizing `b15ac4a`. Review follow-up `c7d05f1` keeps active-volume accounting consistent with the sizing snapshot. Matching issue/PR handoffs are linked above. |
| [apple/container#2037](https://github.com/apple/container/issues/2037) | The reported empty local build context remains open upstream. A 29 July probe against the installed mutable Current package did not reach context transfer: after 153.32 seconds the stopped builder still had not started, and its log showed `unknown flag: --dns-nameserver` because the installed Container binary referenced an older builder digest. The matched development stack pins builder digest `sha256:b48fbf42a51bf3432bd50d64732b4d6931944f3bb30f911a9a513cf8bab9b02e`, which already passed a no-cache context build in 27.71 seconds. Re-run the reporter's exact `COPY` fixture against the next matched Current package before classifying #2037 as reproduced or resolved locally. |

## Open Follow-up

- Keep all supported fork mains current with fetched Apple heads, classify
  every new patch-unique commit, and rerun `make fork-classifications-check`.
- Reconcile merged `apple/containerization#813` into the exact Compose
  Containerization development lane and reassess the older vminitd correction.
- Keep Stephen-authored `apple/container#1934`, `#1935`, `#1965`, `#2031`,
  `#2035`, and `#2036`, and `apple/containerization#799`, `#820`, `#821`, and
  `#823` open until Apple merges, replaces, or explicitly rejects their
  current changes. Track third-party `apple/container-builder-shim#87`
  independently.
- The 29 July refresh found all ten open Stephen-authored Apple pull requests
  mergeable and awaiting review, with no actionable author review. PR #799's
  hosted build, signature, and Linux compile checks are green. Apple Actions
  report `action_required` without starting jobs for the other nine pull
  requests; this is not a failing author check.
- Track `apple/container-builder-shim#89` and its `apple/container#2040`
  integration test without duplicating the equivalent supported resolver.
- Re-run `apple/container#2037` against the next matched Current package. The
  installed package's stale builder digest blocked the first probe before
  context transfer and is not evidence for or against the upstream report.
- Rebase `apple/container#1935` after `apple/container#1862` lands so the preferred upstream XPC commit is not duplicated.
- Split the supported XPC ownership and ProcessIO backpressure corrections
  derived from `stephenlclarke/container#33` into separate stock-shaped
  proposals. Neither has been submitted to Apple.
- Track third-party direct-stream drafts `apple/containerization#812` and
  `apple/container#1947` without importing them verbatim. The supported fork
  now carries an independently reviewed and strengthened implementation; Apple
  convergence still depends on a ready proposal with equivalent metadata,
  cancellation, backpressure, path-safety, sparse-file, and hard-link contracts.
- Generic log-retrieval runtime primitives still need minimal Apple proposals; Docker timestamp parsing remains owned by `container-compose`.
- [apple/container#378](https://github.com/apple/container/issues/378) needs a running-process stream reattach primitive before Compose can support interactive `attach`; the required runtime contract and the deliberate output-only fallback are documented in [ISSUE-attach-stream-reattach.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-container/ISSUE-attach-stream-reattach.md).
- The container storage-boundary follow-up must wait for `apple/container#1735` and retain only its residual `FilePath` and volume-disk-usage protections. The independent `containerization` handoff is ready in [PR-container-storage-path-validation.md](https://github.com/stephenlclarke/container-compose/blob/3d77ec228c7f55a04f689d5e1453752fc0c27f72/docs/upstream/apple-containerization/PR-container-storage-path-validation.md).
- The four unsubmitted builder-shim handoffs have no matching open upstream
  issue or pull request. Keep them separate from
  [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87),
  which changes `.dockerignore` filtering only.
- The reporter's post-fix stop-interruption observation on [apple/containerization#799](https://github.com/apple/containerization/pull/799) is not a requested review change. Keep it under local macOS reproduction before widening the existing copy-failure proposal or opening a separate lifecycle fix.
- The connector review on
  [stephenlclarke/containerization#9](https://github.com/stephenlclarke/containerization/pull/9)
  identified that `LinuxPod` does not yet stage and rewrite a volume
  `sourceSubpath` like `LinuxContainer`. The author has acknowledged the
  actionable thread; retain it as a separate generic runtime follow-up with
  focused pod coverage rather than folding it into Compose CC-001.

## Submission Boundary

Never push to an Apple remote. Upstream imports stay in standalone commits with their original PR and bug references. Locally authored Apple-shaped changes must have focused tests and matching issue/PR handoffs in this directory before their `stephenlclarke` fork branches are proposed to Apple.
