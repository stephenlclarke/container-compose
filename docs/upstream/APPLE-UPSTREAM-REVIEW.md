# Current Apple Upstream Review

This is the current disposition of Apple work that affects the five-repository container stack. Re-check GitHub before changing an Apple-backed component because issue, review, and merge state can change independently.

Updated: 28 July 2026 after fetching every configured Apple and
Stephen-owned remote, querying the live pull-request state, and completing the
31-pull-request stock-Apple port audit and the three strengthened stock
submissions derived from that audit.

## Scope

- `apple/container`
- `apple/containerization`
- `apple/container-builder-shim`

## Fetched Main Baselines

Each supported fork contains its complete Apple `main` history. The
left/right counts below are from `git rev-list --left-right --count
<apple-main>...<fork-main>`:

| Repository | Apple `main` | Supported fork `main` | Apple-only | Fork-only |
| --- | --- | --- | ---: | ---: |
| `container` | `48145ac7fb177d9fb14e015a0bdea4c642b36729` | `367430446959e3048da37f5f64d3c10e1293d3de` | 1 | 327 |
| `containerization` | `3a224e9f909a3e5689bbddd9f3536df091231bb4` | `043193efa5f1a2e21a240041d6edd71d7673739e` | 1 | 133 |
| `container-builder-shim` | `267b5ab98e1d7db7d98af98bdc90578bf5fd3192` | `f97cddf5b3aae2426a094613793c11c41b1d2e53` | 0 | 33 |

The supported `container` fork is one Apple commit behind: Apple PR #2027 at
`48145ac7`. The supported `containerization` fork is one Apple commit behind:
Apple PR #822 at `3a224e9f`. Both moved after the previous fork refresh;
neither delta is silently counted as fork functionality. The fork-only counts
include merge commits and intentionally retained generic runtime work; they are
not a count of changes that are ready for Apple.

## Submitted Stephen-Authored Apple Pull Requests

### Open

All ten open pull requests are ready rather than drafts and report a blocked
merge state while awaiting Apple maintainer review or hosted workflow
approval. No actionable author review is outstanding.

| Pull request | Published head | Current state and purpose |
| --- | --- | --- |
| [apple/container#2036](https://github.com/apple/container/pull/2036) | `45c506815f6c9f500639ea815e502a74bea405fe` | Review required. Close descriptors after failed directory-watch startup, accept descriptor zero, and replace process-wide leak heuristics with deterministic path-specific coverage. No hosted check has been reported. |
| [apple/container#2035](https://github.com/apple/container/pull/2035) | `a8d3b5c87e468a3641ef075c3fce686e206817ad` | Review required. Preserve unloadable bundles, validate runtimes before state insertion, and write root-filesystem metadata atomically. No hosted check has been reported. |
| [apple/container#2031](https://github.com/apple/container/pull/2031) | `58b07fcaa6f09426adc6cd792732c855496ed80f` | Review required. Preserve active and infrastructure image aliases. No hosted check has been reported. |
| [apple/container#1965](https://github.com/apple/container/pull/1965) | `618d28197a20baf643dbdc87272e9f768f57f888` | Review required. Honour generic XPC request timeouts. |
| [apple/container#1935](https://github.com/apple/container/pull/1935) | `f4f908606d4a7693f9bfc958593f7671b35caa0f` | Review required. Keep root help responsive for [apple/container#1459](https://github.com/apple/container/issues/1459); stacked on the preferred cancellation work in [apple/container#1862](https://github.com/apple/container/pull/1862). |
| [apple/container#1934](https://github.com/apple/container/pull/1934) | `d5d73ef1a95ca9f78ffa287b7c2e5204bfd9d569` | Review required. Preserve the complete `unspecified` version placeholder. |
| [apple/containerization#823](https://github.com/apple/containerization/pull/823) | `5d4007ddfa37bd2be77980dfb4b73a31db3232ce` | Review required. Defer restrictive directory attributes without allowing an intermediate symlink to redirect metadata writes outside the extraction root. No hosted check has been reported. |
| [apple/containerization#821](https://github.com/apple/containerization/pull/821) | `726e1ffdceada5cc62d32c8fc939aef30220e6ff` | Review required. Restore permissions after ownership so `fchown` cannot clear set-ID bits. This pull request intentionally depends on #820. No hosted check has been reported. |
| [apple/containerization#820](https://github.com/apple/containerization/pull/820) | `6e32963617b3ed8f4b63432dbcf834f94807342b` | Review required. Preserve sticky, set-user-ID, and set-group-ID archive permission bits. No hosted check has been reported. |
| [apple/containerization#799](https://github.com/apple/containerization/pull/799) | `9c5b9ee19796dc13f0d7d1b0687d780f0db04e29` | Review required with hosted build, signature, and Linux compile checks green. Missing copy sources fail promptly and no longer block later lifecycle operations. |

No Stephen-authored pull request has been submitted to
`apple/container-builder-shim`.

### Merged or closed

| Pull request | Final state | Disposition |
| --- | --- | --- |
| [apple/containerization#798](https://github.com/apple/containerization/pull/798) | Merged 15 July 2026 | The CloudHypervisor SwiftPM exclusion is present in current Apple `main`; no fork-only replacement remains necessary. |
| [apple/container#1933](https://github.com/apple/container/pull/1933) | Closed 22 July 2026 without merge | Superseded by merged production handler work in `apple/container#1981` and `apple/containerization#808`. |
| [apple/container#1838](https://github.com/apple/container/pull/1838) | Closed 27 June 2026 without merge | Superseded by open replacement #1935. |
| [apple/container#1831](https://github.com/apple/container/pull/1831) | Closed 27 June 2026 without merge | Superseded by open replacement #1934. |
| [apple/container#1765](https://github.com/apple/container/pull/1765) | Closed 27 June 2026 without merge | The broad Docker-compatible timestamp parser was not accepted upstream; Docker timestamp parsing remains Compose-owned. |
| [apple/container#1764](https://github.com/apple/container/pull/1764) | Closed 27 June 2026 without merge | The broader log retrieval proposal was not merged; generic log retrieval still needs smaller Apple-shaped primitives. |
| [apple/container#1758](https://github.com/apple/container/pull/1758) | Closed 27 June 2026 without merge | Superseded first by #1933 and then by Apple's merged production handler changes. |

[PR-ARCHIVE.json](PR-ARCHIVE.json) currently retains immutable snapshots for
Apple PRs #1933, #1934, #1935, #1965, containerization PRs #798 and #799, and
third-party builder-shim PR #87. It does not yet archive the heads of newly
submitted PRs #2031, #2035, #2036, #820, #821, or #823; do not describe that
archive as complete until those refs are added and verified.

## Handoff Inventory

There are 128 `PR-*.md` handoff files under the three Apple directories:

| Directory | Files | Submission rule |
| --- | ---: | --- |
| [`apple-container/`](apple-container/) | 88 | `PR-1933.md`, `PR-1934.md`, and `PR-1935.md` map to Stephen-authored submissions. `PR-1926.md` and `PR-1997.md` track existing third-party Apple PRs. `PR-container-test-support-dependencies.md`, `PR-oci-system-paths-api.md`, and `PR-apple-main-sync-20260722-2.md` are downstream reconciliation records. Every other handoff in this directory is unsubmitted. |
| [`apple-containerization/`](apple-containerization/) | 35 | `PR-798.md` and `PR-799.md` map to Stephen-authored submissions. Every other handoff in this directory is unsubmitted. |
| [`apple-container-builder-shim/`](apple-container-builder-shim/) | 5 | `PR-87.md` tracks an existing third-party Apple PR. The other four handoffs are unsubmitted. |

The submitted #1965, #2031, #2035, #2036, #820, #821, and #823 pull requests
do not yet have individual checked-in handoff files. Their live state is
recorded above.

An unsubmitted handoff is not automatically submission-ready. Its own commit
tracking and validation sections determine whether it is a draft,
constructible proposal, downstream-only record, or reviewed candidate. Before
submission, rebase the smallest independent change on current stock Apple
`main`, rerun stock validation, fill the current Apple issue and PR templates,
and keep Stephen-only compatibility behavior out of the patch.

## PR #33 Stock-Apple Review

[stephenlclarke/container#33](https://github.com/stephenlclarke/container/pull/33)
is an open fork PR at
`7ffac9dcf059bd62da87cebe40d20ce05742238c`. Its two defects both exist on
stock `apple/container:main` at
`48145ac7fb177d9fb14e015a0bdea4c642b36729`, but the fork PR is not directly
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

The upstream disposition is to split PR #33 into two unsubmitted,
stock-shaped proposals: one focused XPC `FileHandle` ownership correction
with a stock-compatible descriptor-reuse regression, and one ProcessIO input
pump/backpressure correction adapted to Apple's simpler API. No Apple issue or
pull request has been filed for either slice.

## Audited Open Apple Pull Requests Carried Locally

The 28 July stock-Apple audit reviewed 31 open third-party pull requests and
published the compatible changes only to Stephen-owned cumulative branches:

- `stephenlclarke/container:fix/apple-open-pr-bugfixes-20260728` at
  `be702536bbc166821798e5952c3948e194d95617`
- `stephenlclarke/containerization:fix/apple-open-pr-bugfixes-20260728` at
  `1e5d2c89d0f7056fe48b0b9091abdb3d20cdf7a0`

The initial audit changed only Stephen-owned cumulative branches. Its strict
follow-up review produced stock-based replacement PRs #2035, #2036, and #823
for strengthened versions of #1859, #1773, and #716 respectively. All original
third-party entries below remain open upstream. `Blocked` is GitHub's live
merge state, not a local test failure.

### `apple/container`

Of the 23 carried pull requests, 20 are ready and mergeable but report a
blocked merge state, #1847 is a mergeable draft, and #1719 and #1944 currently
conflict with Apple `main`.

| Apple pull request | Live head and state | Local disposition |
| --- | --- | --- |
| [#1719](https://github.com/apple/container/pull/1719) | `e5440c85a591`, open, conflicting | `1a486c5`: sanitise the sudoers filename and also correct the upstream variable spelling and shell syntax. |
| [#1773](https://github.com/apple/container/pull/1773) | `77196fce3d2d`, open, mergeable, blocked | Replacement [#2036](https://github.com/apple/container/pull/2036) at `45c5068` retains @muk2's production close, accepts descriptor zero, requires a `Sendable` handler, replaces the process-wide threshold with exact path-specific leak detection, and removes watcher-test timing races. |
| [#1832](https://github.com/apple/container/pull/1832) | `ce8d26b0572d`, open, mergeable, blocked | `521f9b7`: stage non-regular image inputs while retaining direct regular-file paths. |
| [#1847](https://github.com/apple/container/pull/1847) | `7506d68bb852`, open draft, mergeable, blocked | `6472d82`: carry only the verified guest-platform kernel selection; the unproved vminit change remains excluded. |
| [#1854](https://github.com/apple/container/pull/1854) | `9a0db6f8507b`, open, mergeable, blocked | `ca6edcc`: keep `SIGWINCH` off the generic process-kill path. |
| [#1859](https://github.com/apple/container/pull/1859) | `f99feb3c1276`, open, mergeable, blocked | Replacement [#2035](https://github.com/apple/container/pull/2035) at `a8d3b5c` credits @radheradhe01, preserves unloadable bundles, makes all bundle metadata writes atomic, validates the runtime before exposing state, and corrects both regressions. |
| [#1860](https://github.com/apple/container/pull/1860) | `df165045ee94`, open, mergeable, blocked | `72a89a0`: revalidate state while holding the lifecycle lock before deletion. |
| [#1861](https://github.com/apple/container/pull/1861) | `27c2b929c4d1`, open, mergeable, blocked | `e8c0d3e`: carry functional commit `c3c7e218a021`; the newer live head only merges Apple `main`, and the functional diff retains stable patch ID `8303849cfd37`. |
| [#1864](https://github.com/apple/container/pull/1864) | `929a03c4d1fb`, open, mergeable, blocked | `e29bd26`: reject IPv4 subnets with no allocatable host addresses using widened arithmetic. |
| [#1870](https://github.com/apple/container/pull/1870) | `4442a27bc699`, open, mergeable, blocked | `bd77f3a`: retain exact references and reject ambiguous displayed names and digest prefixes. |
| [#1891](https://github.com/apple/container/pull/1891) | `a18abb2c1b4d`, open, mergeable, blocked | `30743f0`: retain a separately fetched machine setup-script layer. |
| [#1893](https://github.com/apple/container/pull/1893) | `fb0b879e7450`, open, mergeable, blocked | `4634a80`: use unaligned-safe DNS wire loads and stores with every-offset coverage. |
| [#1896](https://github.com/apple/container/pull/1896) | `8c9bab4d818b`, open, mergeable, blocked | `c7c4282`: reject empty mount keys without losing legal equals signs in values. |
| [#1904](https://github.com/apple/container/pull/1904) | `dfaa3660f131`, open, mergeable, blocked | `8ba4d39`: preserve accepted fractional memory values without byte-rounding loss. |
| [#1909](https://github.com/apple/container/pull/1909) | `9821ca5cebe1`, open, mergeable, blocked | `6d522a0`: cancel terminal resize forwarding when a build completes. |
| [#1944](https://github.com/apple/container/pull/1944) | `8c6903c0d0c7`, open, conflicting | `1f7f0c7`: resolve symlinked configuration sources while retaining atomic replacement and destination-symlink protection. |
| [#1963](https://github.com/apple/container/pull/1963) | `9624e8c86186`, open, mergeable, blocked | `6f49926`: resolve local digest references before normalising names or pulling. |
| [#2016](https://github.com/apple/container/pull/2016) | `49dfdd87e138`, open, mergeable, blocked | `38e1572`: split mount directives only on the first equals sign. |
| [#2017](https://github.com/apple/container/pull/2017) | `3fdcc573a6d4`, open, mergeable, blocked | `cb2dceb`: normalise a trailing equals sign to an empty value. |
| [#2018](https://github.com/apple/container/pull/2018) | `dfa60b167af8`, open, mergeable, blocked | `522a2b3`: accept valid TCP and UDP port 1 while retaining port 0 rejection. |
| [#2019](https://github.com/apple/container/pull/2019) | `0467f2429755`, open, mergeable, blocked | `6d21802`: close a UDP backend that becomes active after eviction. |
| [#2025](https://github.com/apple/container/pull/2025) | `85dd2a92c7b1`, open, mergeable, blocked | `544f8a7`: require an executable regular `/sbin/init` and clean up failed machine creation. |
| [#2027](https://github.com/apple/container/pull/2027) | `16bec754b36b`, open, mergeable, blocked | `42bc06e`: retain the complete verified security set plus fork named-context, interface-binding, path-normalisation, and regression requirements. |

### `apple/containerization`

Seven of the eight carried pull requests are mergeable with a blocked merge
state. #748 currently conflicts with Apple `main`.

| Apple pull request | Live head and state | Local disposition |
| --- | --- | --- |
| [#715](https://github.com/apple/containerization/pull/715) | `29dfe1b9e847`, open, mergeable, blocked | `ad950d4`: bound the manifest GET fallback and derive its descriptor from returned bytes. |
| [#716](https://github.com/apple/containerization/pull/716) | `77da467c16d8`, open, mergeable, blocked | Replacement [#823](https://github.com/apple/containerization/pull/823) at `5d4007d` credits @JaewonHur, traverses every component descriptor-relative without following symlinks, preserves last-entry-wins metadata, and proves an intermediate symlink cannot escape the extraction root. |
| [#717](https://github.com/apple/containerization/pull/717) | `5c0fe3668529`, open, mergeable, blocked | `b992252`: retain requested size for ordinary partial groups and round only tiny metadata-constrained final groups. |
| [#748](https://github.com/apple/containerization/pull/748) | `79f4658de009`, open, conflicting | `5184c6e`: allow Swift Crypto 3 or 4 and resolve the fork to 4.5.1. |
| [#768](https://github.com/apple/containerization/pull/768) | `5835a86b3bc0`, open, mergeable, blocked | `d6322d3`: classify Basic-auth registry failures as credential errors. |
| [#783](https://github.com/apple/containerization/pull/783) | `7eb0c7df41ee`, open, mergeable, blocked | `6a1370e`: canonicalise arm64 platform descriptions without redundant `v8`. |
| [#796](https://github.com/apple/containerization/pull/796) | `6c46194ca394`, open, mergeable, blocked | `310932e`: reject invalid bridge interface names before indexing or allocation. |
| [#813](https://github.com/apple/containerization/pull/813) | `542463261721`, open, mergeable, blocked | `1cec794`: redact environment values while retaining useful variable names in debug logs. |

### Strengthened Changes Submitted to Apple

The later changes for #1859, #1773, and #716 were confirmed as generic Apple
fixes rather than Compose compatibility additions. Each was rebuilt on stock
Apple `main`, credits the original author, documents reproduction and
validation in the current repository template, and is now submitted as a
ready replacement. The `apple/container` replacements also link the required
bug reports:

| Original pull request | Replacement and disposition |
| --- | --- |
| [apple/container#1859](https://github.com/apple/container/pull/1859) | [#2035](https://github.com/apple/container/pull/2035), fixing [#2033](https://github.com/apple/container/issues/2033), at `a8d3b5c`. Runtime validation now precedes state insertion, root-filesystem metadata uses the same atomic durability rule as other bundle JSON, and corrected malformed-data and missing-runtime tests prove both behaviours. |
| [apple/container#1773](https://github.com/apple/container/pull/1773) | [#2036](https://github.com/apple/container/pull/2036), fixing [#2034](https://github.com/apple/container/issues/2034), at `45c5068`. The correct production close from @muk2 is retained, descriptor zero and the escaping handler contract are corrected, and the weak process-wide threshold is replaced by exact path-specific leak detection with 32 verified handler calls. This replacement deliberately does not close [#1097](https://github.com/apple/container/issues/1097), whose guest virtiofs workload has no established causal path through the host DNS directory watcher. |
| [apple/containerization#716](https://github.com/apple/containerization/pull/716) | [#823](https://github.com/apple/containerization/pull/823) at `5d4007d`, the highest-priority security correction. `O_NOFOLLOW` on one `openat` call protects only the final path component. Component-wise descriptor traversal now prevents an intermediate symlink redirecting deferred metadata outside the extraction root, while canonical last-entry-wins state preserves archive semantics. It was validated at `50f7722`; Apple `main` then gained only #822's unrelated `linux_run` Makefile change, and GitHub still reports the PR mergeable and blocked. |

### Recorded Validation Timings

Timings are behavioural evidence and optimisation baselines, not pass/fail
thresholds by themselves. The positive and negative command times include
different incremental rebuild costs, so test-level timings are the comparable
signal here.

- #2035 stock negative control: the two corrected persistence tests failed with
  four issues in 0.016 seconds; command wall time 94.56 seconds including the
  stock build. The replacement branch passed both tests in 0.006 seconds;
  command wall time 201.58 seconds including its fresh dependency build.
- #2035 full gate: 591 tests in 72 suites passed in 2.011 seconds; command wall
  time 119.33 seconds. `HAWKEYE_AUTO_INSTALL=1 make check` also passed.
- #2036 stock negative control: the single path-specific test failed in 0.010
  seconds with exactly 32 watched-directory descriptors left open from a zero
  baseline; command wall time 0.63 seconds after the stock test build.
- #2036 focused gate: 5 tests in 1 suite passed in 1.030 seconds; command wall
  time 97.49 seconds including a clean dependency rebuild.
- #2036 full gate: 590 tests in 71 suites passed in 1.233 seconds; command wall
  time 103.47 seconds including the repository build.
  `HAWKEYE_AUTO_INSTALL=1 make check` also passed.
- #823 stock and original-#716 negative controls: the corrected read-only
  directory test failed on stock in 0.013 seconds; the intermediate-symlink
  escape failed against #716 in 0.011 seconds; and its aliased
  last-entry-wins case failed in 0.008 seconds.
- #823 focused gates: 25 archive-reader tests passed in 43.191 seconds and 28
  descriptor-operation tests passed in 18.504 seconds. The full gate passed
  578 tests in 80 suites in 45.134 seconds; the final clean
  `make check && make test` command completed in 150.37 seconds.
- The earlier cumulative-fork validation remains supporting evidence: 1,223
  container tests in 146 suites passed in 12.314 seconds, and 669
  containerization tests in 86 suites passed in 151.545 seconds.

No test hung and no material slowdown attributable to these hardenings was
observed. Preserve these timings with future parity and optimisation runs;
slower completion is not itself a parity failure unless it is materially
slower in practical use or does not complete.

## Unsubmitted Review Candidates

| Repository | Current purpose |
| --- | --- |
| `apple/container` | [Generic IPv6 network disablement](apple-container/PR-network-ipv6-disablement.md) adds a typed macOS vmnet NAT66 and router-advertisement control while retaining enabled compatibility by default. |
| `apple/container-builder-shim` | [Build-context source-read errors](apple-container-builder-shim/PR-build-context-source-read-errors.md) fail explicitly instead of sending empty file content. |
| `apple/container-builder-shim` | [Build-context cache integrity](apple-container-builder-shim/PR-build-context-cache-integrity.md) verifies archives, atomically publishes cache trees, and keeps synthetic Dockerfiles request-local. |
| `apple/container` | [Fork CI validation](apple-container/PR-fork-ci-validation.md) runs formatting, generated-source checks, builds, and unit tests in contributor forks while retaining official guest integration. |
| `apple/container` | [Live filesystem snapshot export](apple-container/PR-live-export-snapshot.md) adds a generic `export --live` primitive for a running container, based on the direction in [apple/container#1630](https://github.com/apple/container/pull/1630). |
| `apple/container` | [Additional guest interface addresses](apple-container/PR-additional-interface-addresses.md) carry generic typed CIDRs through runtime attachment strategies. |
| `apple/container` | [Requested primary network addresses](apple-container/PR-requested-primary-network-addresses.md) reserve generic typed IPv4 and IPv6 attachment addresses with collision checks. |
| `apple/container` | [IPv4 network gateway configuration](apple-container/PR-network-ipam-gateway.md) carries a validated generic gateway through persisted network configuration, helper startup, vmnet setup, and attachment allocation. |
| `apple/container` | [IPv4 allocation-range configuration](apple-container/PR-network-ipam-allocation-range.md) carries a generic dynamic-allocation CIDR through persisted network configuration, helper startup, and attachment allocation. |
| `apple/container` | [IPv4 network address reservations](apple-container/PR-network-ipv4-reserved-addresses.md) carry validated generic reservations through persisted network configuration, helper startup, and attachment allocation. |
| `apple/container` | [Numeric supplemental process groups](apple-container/PR-supplemental-groups.md) expose the runtime's existing typed GID support through the generic process CLI surface. |
| `apple/container` | [Owned regular-file bind snapshots](apple-container/PR-file-mount-ownership.md) expose optional UID/GID mapping without mutating the host source. |
| `apple/container` | [Compiled build glob caching](apple-container/PR-build-glob-cache.md) compiles each Docker ignore pattern once per context while retaining the existing Swift regex semantics. |
| `apple/container` | [Hashed build-context membership](apple-container/PR-build-context-membership.md) uses the existing `Set<DirEntry>` contract instead of scanning it linearly for each archive candidate. |
| `apple/container` | [Concurrent stats sampling](apple-container/PR-stats-concurrent-sampling.md) fans out independent runtime samples while preserving list order and failure semantics. |
| `apple/container` | [Disk-usage lock scope](apple-container/PR-disk-usage-lock-scope.md) snapshots metadata under service locks and traverses resource trees on detached utility tasks. |
| `apple/containerization` | [Fork CI validation](apple-containerization/PR-fork-ci-validation.md) runs supported checks in contributor forks while retaining official guest image and integration work. |
| `apple/containerization` | [Additional guest interface addresses](apple-containerization/PR-additional-interface-addresses.md) configure generic supplemental IPv4/IPv6 CIDRs before link-up. |
| `apple/containerization` | [Owned regular-file bind snapshots](apple-containerization/PR-file-mount-ownership.md) create private guest copies only when ownership metadata is requested. |
| `apple/containerization` | [Cgroup formatter catch spacing](apple-containerization/PR-cgroup-catch-format.md) restores the exact spelling required by the strict Swift formatter without changing runtime behavior. |
| `apple/containerization` | [vmnet integration exclusivity](apple-containerization/PR-vmnet-integration-exclusivity.md) serializes only host-networking VM tests so release validation remains deterministic. |

These candidates remain unsubmitted. Their source commits and tests were
reviewed in the fork, but each still requires a fresh stock-Apple rebase and
validation before submission.

## Overlapping Upstream Work

| Pull request | Local disposition |
| --- | --- |
| [apple/container#1862](https://github.com/apple/container/pull/1862) | Preferred XPC cancellation implementation. Imported unchanged as the first standalone commit in `apple/container#1935`, with deterministic tests in the next commit. Drop the import when this PR lands. |
| [apple/container#1926](https://github.com/apple/container/pull/1926) | Its attached-exec disconnect cleanup is represented in `stephenlclarke/container`; its separate stop-timeout path still needs single-owner cleanup review. |
| [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87) | Its `.dockerignore` re-included-parent fix is represented by standalone commit `2778407`; the fork retains its staged-Dockerfile safeguard until the upstream shape lands. |
| [apple/container#1735](https://github.com/apple/container/pull/1735) | Preferred daemon entry-point ID validation. Imported as standalone commit `16ecfd5`; the broader residual bundle-path and volume-disk-usage hardening is tracked in [PR-container-storage-path-validation.md](apple-container/PR-container-storage-path-validation.md) and must follow this PR rather than compete with it. |
| [apple/container#1630](https://github.com/apple/container/pull/1630) | The local live-export handoff is a generic snapshot primitive based on this direction. It uses a unique temporary snapshot and serializes the freeze/copy/thaw lifecycle; it deliberately does not add Docker-shaped `container commit` behavior from [apple/container#1762](https://github.com/apple/container/pull/1762). |

## Tracked Third-Party Apple Pull Requests

| Pull request | Local disposition |
| --- | --- |
| [apple/container#1818](https://github.com/apple/container/pull/1818) | Closed 20 July 2026 without merge. The ordered-journaling source change remains a fork-only standalone commit at `6e525cc`. |
| [apple/container#1708](https://github.com/apple/container/pull/1708) | Open, approved, and currently conflicting. Already represented by the machine-configuration documentation in `3bb6864`. |
| [apple/container#1660](https://github.com/apple/container/pull/1660) | Open and approved. Already represented by the application-root backup exclusion in `3bb6864`. |
| [apple/container#1508](https://github.com/apple/container/pull/1508) | Open, mergeable, and awaiting review. It is not copied because the local SSH forwarding implementation supports default, explicit, and multiple named sockets. Reconcile with upstream if this PR changes or lands. |
| [apple/container#730](https://github.com/apple/container/pull/730) | Open and approved. Already represented in `3bb6864`, plus the parse-entry correction required by the fork's `@main` wrapper. |
| [apple/containerization#753](https://github.com/apple/containerization/pull/753) | Open and approved. Already represented by `8de8a10`, including default client ID, caller override, and request-header tests. |
| [apple/container#1889](https://github.com/apple/container/pull/1889) | Merged 23 July 2026 and present in the current Apple baseline. The earlier fork port at `0fe7833` is now retained only as ancestry. |
| [apple/container#1997](https://github.com/apple/container/pull/1997) | Open, mergeable, and awaiting review. Its content-identical signal-name correction is represented by `bb2438c`. |
| [apple/container#2000](https://github.com/apple/container/pull/2000) | Closed 28 July 2026 without merge. The fork's existing backward-read tests continue to cover the reported behaviour. |
| [apple/containerization#792](https://github.com/apple/containerization/pull/792) | Open, mergeable, and awaiting review. Its fresh-session registry retry behaviour is represented by `d388a15` and `c8043bb`. |

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
| [apple/container#1977](https://github.com/apple/container/issues/1977) | Labels now split only at their first `=` in `stephenlclarke/container` `47c13a8`; the Apple-shaped handoff and Compose v2 parity follow-through are recorded in [PR-label-value-equals.md](apple-container/PR-label-value-equals.md) and [PR-label-value-equals.md](container-compose/PR-label-value-equals.md). |
| [apple/container#1969](https://github.com/apple/container/issues/1969) | `container copy` now splits a container path reference only at its first `:` in `stephenlclarke/container` `f03ae57`, so legal colons in guest paths are retained. The generic runtime and Compose dependency handoffs are recorded in [PR-copy-path-colon.md](apple-container/PR-copy-path-colon.md) and [PR-copy-path-colon.md](container-compose/PR-copy-path-colon.md). |
| Isolated runtime startup | A stale same-label launchd service no longer binds a new `--app-root` to an older XPC helper. The generic macOS correction is `stephenlclarke/container` `7272c40`; its issue/PR handoff is [ISSUE-launchd-service-ownership.md](apple-container/ISSUE-launchd-service-ownership.md) and [PR-launchd-service-ownership.md](apple-container/PR-launchd-service-ownership.md). |
| Compose image-volume subpath teardown | Generic `LinuxContainer` cleanup now unmounts staged subpath binds and their backing volumes so the guest root is removable without `EBUSY`; fixed in `stephenlclarke/containerization` `93d7710` and documented by [ISSUE-staged-subpath-mount-cleanup.md](apple-containerization/ISSUE-staged-subpath-mount-cleanup.md) and [PR-staged-subpath-mount-cleanup.md](apple-containerization/PR-staged-subpath-mount-cleanup.md). |
| Compose completed dependency state | A one-shot dependency reported as `exited` now satisfies `service_completed_successfully` when its stored exit code is zero, matching the existing `stopped` handling. The Compose-only correction is `74d02bb` and is documented by [ISSUE-completed-dependency-exited-status.md](container-compose/ISSUE-completed-dependency-exited-status.md) and [PR-completed-dependency-exited-status.md](container-compose/PR-completed-dependency-exited-status.md). |
| Compose unconfigured image-volume provider | Library-only image-volume planning no longer interprets a missing runtime provider as an image with no declared volumes. The Compose-only correction is `5d532790`, with full provider-contract coverage and handoffs in [ISSUE-unconfigured-runtime-image-volume-provider.md](container-compose/ISSUE-unconfigured-runtime-image-volume-provider.md) and [PR-unconfigured-runtime-image-volume-provider.md](container-compose/PR-unconfigured-runtime-image-volume-provider.md). |
| Concurrent Compose image builds | Generic BuildKit startup now serializes only the macOS inspect/create/bootstrap lifecycle for each builder, so concurrent Compose builds reuse the `buildkit` singleton instead of receiving `container already exists`. The correction is `stephenlclarke/container` `7be83a2`; its issue/PR handoff is [ISSUE-builder-startup-race.md](apple-container/ISSUE-builder-startup-race.md) and [PR-builder-startup-race.md](apple-container/PR-builder-startup-race.md). |
| Quiet machine-list integration | The generic `machine ls -q` test no longer assumes exclusive ownership of the runtime-wide machine list. It verifies that its own machine is listed without a table header, while retaining other legitimate entries; fixed in `stephenlclarke/container` `e36445b` and documented by [ISSUE-machine-list-quiet-test-isolation.md](apple-container/ISSUE-machine-list-quiet-test-isolation.md) and [PR-machine-list-quiet-test-isolation.md](apple-container/PR-machine-list-quiet-test-isolation.md). |
| Compose follow-log XPC decoding | A one-descriptor `container logs --follow` reply no longer makes the generic macOS XPC client duplicate an out-of-range second descriptor and trap. The correction is `stephenlclarke/container` `a8f6cae`; its issue/PR handoff is [ISSUE-xpc-variable-descriptor-arrays.md](apple-container/ISSUE-xpc-variable-descriptor-arrays.md) and [PR-xpc-variable-descriptor-arrays.md](apple-container/PR-xpc-variable-descriptor-arrays.md). |
| Compose child-process cancellation | Cancelling a Compose task now owns and terminates its complete host process group across captured, prompt-inheriting, inherited, and explicit-stdin modes. The Compose-only correction is `044d836d`, reusing `ContainerizationOS.Command` for group creation with atomically latched and bounded TERM-to-KILL escalation, ownership-checked and `SIGTTOU`-safe terminal handoff/restoration, independent background job-control group tracking, `WUNTRACED` stop relay through the parent shell job, per-pipe broken-pipe handling, and handoffs in [ISSUE-process-runner-task-cancellation.md](container-compose/ISSUE-process-runner-task-cancellation.md) and [PR-process-runner-task-cancellation.md](container-compose/PR-process-runner-task-cancellation.md). Exit restores the retained parent group only while the child still owns the terminal, including after an `fg` resume. No Apple runtime fork change is required. |
| Compose package preflight output | Runtime package and service checks now reuse the asynchronous Compose process runner, so stdout and stderr drain while each child runs and cancellation owns the exact process group. Compose-only corrections `81d32eb2`, `96ac7830`, `045d020c`, `9db8f060`, `e0ad1dfe`, `4bf2eac6`, `3ed87228`, `fbe0ce05`, `b65d18a6`, `62a40d48`, `b07e9da8`, and `5b6f4880` bound retained output at the process-drain boundary and displayed failures at a 64 KiB absolute raw-stream boundary without splitting valid UTF-8 scalars even after leading-whitespace trimming, preserve exact omitted source-byte counts for malformed output and whitespace-only retained prefixes, report content that starts beyond a whitespace-consumed display budget, scan large diagnostics without a proportional per-byte object model, retain stderr priority, retain public `CommandResult` equality and unbounded runner semantics, preserve `CancellationError` from both compatibility awaits, install signal handling before child-task creation, synchronously register delivered signal handlers, drain dispatch-source cancellation, and await those handlers before accepting the proxied result. This guarantees the preflight group is cancelled and reaped before a host signal becomes the CLI shell status. Test correction `592266a7` exercises a 16 MiB packaged-CLI failure below a 320 MiB maximum resident-memory ceiling. The large-output, bounded-capture, diagnostic, memory, signal, cancellation, and child-reaping evidence is recorded in [ISSUE-package-compatibility-preflight-drain.md](container-compose/ISSUE-package-compatibility-preflight-drain.md) and [PR-package-compatibility-preflight-drain.md](container-compose/PR-package-compatibility-preflight-drain.md). No Apple runtime fork change is required. |
| Compose process-start observation | The exact-main SonarCloud analysis for child-process cancellation identified one undocumented no-op observer and two nested launch-observer closures. Compose-only correction `7939874a` names the private callback contract, invokes it through one helper outside the asynchronous continuation bodies, and explains the production no-op without changing launch or cancellation behavior. Follow-up merge `617c2036` passed exact-main analysis `fe1e52b4-9674-4da6-90f8-ce4b0155909d` with zero unresolved issues or hotspots. See [ISSUE-process-start-observer-maintainability.md](container-compose/ISSUE-process-start-observer-maintainability.md) and [PR-process-start-observer-maintainability.md](container-compose/PR-process-start-observer-maintainability.md). |
| Current VHS runtime startup | The self-hosted Current release runner now requires the global Container launchd namespace to remain absent before recording, repeats that guard after a transport-only reset, and visibly types one bounded retry of the exact packaged-runtime start. This is Compose release-layer recovery for an XPC interruption after a long retained-runtime stop; it changes no Apple runtime source and introduces no Replay, Marker, or transcript path. Four signed commits merged as `4b4a4cff`; exact-main CI, CodeQL, and SonarCloud analysis `b31c11e9-089a-4c1e-b3c6-44967b74ad79` passed with zero unresolved issues or hotspots. Current run `30231378606` published matched checksummed and SLSA-attested archives plus a 303.92-second GIF whose commands and real output are live, with 16 `Type`, 16 `Enter`, 14 `Wait`, zero Replay, and zero Marker instructions. See [ISSUE-current-vhs-start-recovery.md](container-compose/ISSUE-current-vhs-start-recovery.md) and [PR-current-vhs-start-recovery.md](container-compose/PR-current-vhs-start-recovery.md). |
| Current full-dispatch authority | A docs-only main merge requires explicit full-validation CI to establish runtime, coverage, and SonarCloud authority. Current's controller accepted that exact successful `workflow_dispatch`, but its independent package-time guard pre-filtered to push events and rejected the same run after cache restoration. Compose-only correction `c8524d36` accepts successful exact-main CI from the existing trusted `push` or `workflow_dispatch` set and continues to exclude all other events. See [ISSUE-current-dispatch-release-authority.md](container-compose/ISSUE-current-dispatch-release-authority.md) and [PR-current-dispatch-release-authority.md](container-compose/PR-current-dispatch-release-authority.md). |
| Current dependency cache overhead | Current run `30235634675` spent 10 minutes restoring a 2.13 GB SwiftPM cache and 19 minutes 19 seconds attempting a 1.62 GB Go cache restore, versus 2 minutes 25 seconds and 2 minutes 17 seconds for the respective runtime and Compose builds. Compose-only correction `6cae9a84` removes the release SwiftPM cache and disables release `setup-go` caching while retaining all validation-workflow caches. See [ISSUE-release-dependency-cache-overhead.md](container-compose/ISSUE-release-dependency-cache-overhead.md) and [PR-release-dependency-cache-overhead.md](container-compose/PR-release-dependency-cache-overhead.md). |
| [apple/container#1941](https://github.com/apple/container/issues/1941) | The supported fork ports the content-identical signal-name correction from [apple/container#1997](https://github.com/apple/container/pull/1997) in `bb2438c`, with regression coverage in `26cc778` and handoff details in [PR-1997.md](apple-container/PR-1997.md). Drop the port when Apple merges an equivalent fix. |
| [apple/container#1967](https://github.com/apple/container/issues/1967) | [apple/container#2000](https://github.com/apple/container/pull/2000) closed 28 July 2026 without merge. The supported `LogFileOutput` already retains complete records across backward-read chunks; explicit 3 KB and multi-record tests in `26cc778` cover the reported behaviour. |
| [apple/container#2009](https://github.com/apple/container/issues/2009) | The supported init-process reattach path writes persistent sinks first and removes failed clients through `AttachableOutput`; `26cc778` proves later persistent writes continue. Apple main still needs its own reviewed fix. |
| [apple/containerization#798](https://github.com/apple/containerization/pull/798) | Merged upstream. Its SwiftPM manifest correction is included in the current Apple baseline, so it no longer needs fork-side review or a local port. |
| [apple/container#2021](https://github.com/apple/container/issues/2021) | Host disk-space retention after deleting guest files is owned by the macOS Virtualization.framework virtio-fs implementation and is released when the container stops. The supported stack must not add a divergent copy, remount, or guest-filesystem workaround for an Apple OS primitive. Track the upstream platform resolution. |
| [apple/container#2022](https://github.com/apple/container/issues/2022) | The reported long-line `logs -n` correctness case passes on the installed supported runtime with a 2,001-byte first record and exact final three records. The four reported hot-path inefficiencies reproduce in the fork and are corrected as independent signed commits: glob cache `abab498f` plus Unicode-semantics correction `4436afe`, hashed context membership `41e31f7`, concurrent stats `600fde2`, and off-lock disk sizing `b15ac4a`. Review follow-up `c7d05f1` keeps active-volume accounting consistent with the sizing snapshot. Matching issue/PR handoffs are linked above. |

## Open Follow-up

- Keep Stephen-authored `apple/container#1934`, `#1935`, `#1965`, `#2031`,
  `#2035`, and `#2036`, and `apple/containerization#799`, `#820`, `#821`, and
  `#823` open until Apple merges, replaces, or explicitly rejects their current
  changes. Track third-party `apple/container-builder-shim#87` independently.
- The final 28 July refresh found all ten Stephen-authored Apple pull requests
  ready, blocked, and awaiting review, with no actionable author review. PR
  #799's hosted build, signature, and Linux compile checks are green. No hosted
  check has yet been reported for #2031, #2035, #2036, #820, #821, or #823.
- Refresh the supported `container` and `containerization` fork mains for Apple
  #2027 and #822 respectively, then rerun the linked-stack gates before
  claiming zero-behind status.
- Rebase `apple/container#1935` after `apple/container#1862` lands so the preferred upstream XPC commit is not duplicated.
- Split `stephenlclarke/container#33` into separate stock-shaped XPC ownership
  and ProcessIO backpressure proposals. Neither has been submitted to Apple.
- Generic log-retrieval runtime primitives still need minimal Apple proposals; Docker timestamp parsing remains owned by `container-compose`.
- [apple/container#378](https://github.com/apple/container/issues/378) needs a running-process stream reattach primitive before Compose can support interactive `attach`; the required runtime contract and the deliberate output-only fallback are documented in [ISSUE-attach-stream-reattach.md](apple-container/ISSUE-attach-stream-reattach.md).
- The container storage-boundary follow-up must wait for `apple/container#1735` and retain only its residual `FilePath` and volume-disk-usage protections. The independent `containerization` handoff is ready in [PR-container-storage-path-validation.md](apple-containerization/PR-container-storage-path-validation.md).
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
