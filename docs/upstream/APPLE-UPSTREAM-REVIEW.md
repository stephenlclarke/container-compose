# Current Apple Upstream Review

This is the current disposition of Apple work that affects the five-repository container stack. Re-check GitHub before changing an Apple-backed component because issue, review, and merge state can change independently.

## Scope

- `apple/container`
- `apple/containerization`
- `apple/container-builder-shim`

## Fetched Main Baselines

The 27 July 2026 refresh fetched every configured Apple and Stephen-owned
remote before comparison. Each supported fork contains its complete Apple
`main` history:

| Repository | Apple `main` | Supported fork `main` | Apple-only commits |
| --- | --- | --- | ---: |
| `container` | `d1d763530df3c6a326dbae7f0c0a59a335808045` | `5796a79ee3e59c16098d086278c072740d519ee8` | 0 |
| `containerization` | `74ace148ded72f7bb3c878b142e4962ae668adf4` | `164088e02e16ed80e536d0c59822b09931d213df` | 0 |
| `container-builder-shim` | `267b5ab98e1d7db7d98af98bdc90578bf5fd3192` | `f97cddf5b3aae2426a094613793c11c41b1d2e53` | 0 |

No Apple commit needed merging in this refresh. The runtime maintenance head
`281208b1a8db06c92348afdeb1c163e043637c16` passed exact-head review and
hosted checks, then merged without tree changes as
`5796a79ee3e59c16098d086278c072740d519ee8`. The Compose and Homebrew support
repositories also had no open dependency-bot pull requests.

## Open stephenlclarke Proposals

| Pull request | Current purpose |
| --- | --- |
| [apple/container#1934](https://github.com/apple/container/pull/1934) | Ready-for-review fix that preserves the complete `unspecified` version placeholder. |
| [apple/container#1935](https://github.com/apple/container/pull/1935) | Ready-for-review root-help responsiveness fix for [apple/container#1459](https://github.com/apple/container/issues/1459), stacked on [apple/container#1862](https://github.com/apple/container/pull/1862). |
| [apple/container#1965](https://github.com/apple/container/pull/1965) | Ready-for-review request-timeout correction; retain as an independent generic XPC lifecycle proposal while it awaits maintainer review. |
| [apple/containerization#799](https://github.com/apple/containerization/pull/799) | Ready-for-review fix for [apple/container#1927](https://github.com/apple/container/issues/1927): missing copy sources fail promptly, preserve the guest error, and no longer block later container lifecycle operations. |

The exact current heads of these proposals, plus
[apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87),
are retained as immutable stephenlclarke-owned branches in
[PR-ARCHIVE.json](PR-ARCHIVE.json). The daily archive verification workflow
fails if any snapshot is deleted or retargeted.

## Ready Apple Handoffs

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

## Overlapping Upstream Work

| Pull request | Local disposition |
| --- | --- |
| [apple/container#1862](https://github.com/apple/container/pull/1862) | Preferred XPC cancellation implementation. Imported unchanged as the first standalone commit in `apple/container#1935`, with deterministic tests in the next commit. Drop the import when this PR lands. |
| [apple/container#1926](https://github.com/apple/container/pull/1926) | Its attached-exec disconnect cleanup is represented in `stephenlclarke/container`; its separate stop-timeout path still needs single-owner cleanup review. |
| [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87) | Its `.dockerignore` re-included-parent fix is represented by standalone commit `2778407`; the fork retains its staged-Dockerfile safeguard until the upstream shape lands. |
| [apple/container#1735](https://github.com/apple/container/pull/1735) | Preferred daemon entry-point ID validation. Imported as standalone commit `16ecfd5`; the broader residual bundle-path and volume-disk-usage hardening is tracked in [PR-container-storage-path-validation.md](apple-container/PR-container-storage-path-validation.md) and must follow this PR rather than compete with it. |
| [apple/container#1630](https://github.com/apple/container/pull/1630) | The local live-export handoff is a generic snapshot primitive based on this direction. It uses a unique temporary snapshot and serializes the freeze/copy/thaw lifecycle; it deliberately does not add Docker-shaped `container commit` behavior from [apple/container#1762](https://github.com/apple/container/pull/1762). |

## Approved Open Pull Requests

| Pull request | Local disposition |
| --- | --- |
| [apple/container#1818](https://github.com/apple/container/pull/1818) | Ported as `6e525cc`; this exact ordered-journaling source change remains a standalone upstream commit. |
| [apple/container#1708](https://github.com/apple/container/pull/1708) | Already represented by the machine-configuration documentation in `3bb6864`. |
| [apple/container#1660](https://github.com/apple/container/pull/1660) | Already represented by the application-root backup exclusion in `3bb6864`. |
| [apple/container#1508](https://github.com/apple/container/pull/1508) | Approved but currently conflicting. It is not copied because the local SSH forwarding implementation supports default, explicit, and multiple named sockets. Reconcile with upstream if this PR changes or lands. |
| [apple/container#730](https://github.com/apple/container/pull/730) | Already represented in `3bb6864`, plus the parse-entry correction required by the fork's `@main` wrapper. |
| [apple/containerization#753](https://github.com/apple/containerization/pull/753) | Already represented by `8de8a10`, including default client ID, caller override, and request-header tests. |

## Confirmed Local Impact

| Upstream report | Current resolution |
| --- | --- |
| [apple/containerization#518](https://github.com/apple/containerization/issues/518) | Exec debug logging no longer serializes environment-backed secrets; fixed in `f17ec69`. |
| [apple/container#1917](https://github.com/apple/container/issues/1917) | Generated resolver files no longer pollute the macOS global search list; fixed in `stephenlclarke/container` `160035f`. |
| [apple/container#1888](https://github.com/apple/container/issues/1888) | The focused stderr change from [apple/container#1889](https://github.com/apple/container/pull/1889) is ported as `0fe7833`. |
| [apple/container#1672](https://github.com/apple/container/issues/1672) | [apple/container#1717](https://github.com/apple/container/pull/1717) is ported as `7329f12`. |
| [apple/container#1767](https://github.com/apple/container/issues/1767) | Approved [apple/container#1818](https://github.com/apple/container/pull/1818) is ported as `6e525cc`. |
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
| Compose package preflight output | Runtime package and service checks now reuse the asynchronous Compose process runner, so stdout and stderr drain while each child runs and cancellation owns the exact process group. Compose-only corrections `81d32eb2`, `96ac7830`, `045d020c`, `9db8f060`, and `e0ad1dfe` also bound displayed failures at a 64 KiB raw-stream boundary without splitting valid UTF-8 scalars, preserve exact omitted source-byte counts for malformed output, scan large diagnostics without a proportional per-byte object model, and preserve `CancellationError` from both compatibility awaits. The large-output, diagnostic, cancellation, and child-reaping evidence is recorded in [ISSUE-package-compatibility-preflight-drain.md](container-compose/ISSUE-package-compatibility-preflight-drain.md) and [PR-package-compatibility-preflight-drain.md](container-compose/PR-package-compatibility-preflight-drain.md). No Apple runtime fork change is required. |
| Compose process-start observation | The exact-main SonarCloud analysis for child-process cancellation identified one undocumented no-op observer and two nested launch-observer closures. Compose-only correction `7939874a` names the private callback contract, invokes it through one helper outside the asynchronous continuation bodies, and explains the production no-op without changing launch or cancellation behavior. Follow-up merge `617c2036` passed exact-main analysis `fe1e52b4-9674-4da6-90f8-ce4b0155909d` with zero unresolved issues or hotspots. See [ISSUE-process-start-observer-maintainability.md](container-compose/ISSUE-process-start-observer-maintainability.md) and [PR-process-start-observer-maintainability.md](container-compose/PR-process-start-observer-maintainability.md). |
| Current VHS runtime startup | The self-hosted Current release runner now requires the global Container launchd namespace to remain absent before recording, repeats that guard after a transport-only reset, and visibly types one bounded retry of the exact packaged-runtime start. This is Compose release-layer recovery for an XPC interruption after a long retained-runtime stop; it changes no Apple runtime source and introduces no Replay, Marker, or transcript path. Four signed commits merged as `4b4a4cff`; exact-main CI, CodeQL, and SonarCloud analysis `b31c11e9-089a-4c1e-b3c6-44967b74ad79` passed with zero unresolved issues or hotspots. Current run `30231378606` published matched checksummed and SLSA-attested archives plus a 303.92-second GIF whose commands and real output are live, with 16 `Type`, 16 `Enter`, 14 `Wait`, zero Replay, and zero Marker instructions. See [ISSUE-current-vhs-start-recovery.md](container-compose/ISSUE-current-vhs-start-recovery.md) and [PR-current-vhs-start-recovery.md](container-compose/PR-current-vhs-start-recovery.md). |
| Current full-dispatch authority | A docs-only main merge requires explicit full-validation CI to establish runtime, coverage, and SonarCloud authority. Current's controller accepted that exact successful `workflow_dispatch`, but its independent package-time guard pre-filtered to push events and rejected the same run after cache restoration. Compose-only correction `c8524d36` accepts successful exact-main CI from the existing trusted `push` or `workflow_dispatch` set and continues to exclude all other events. See [ISSUE-current-dispatch-release-authority.md](container-compose/ISSUE-current-dispatch-release-authority.md) and [PR-current-dispatch-release-authority.md](container-compose/PR-current-dispatch-release-authority.md). |
| Current dependency cache overhead | Current run `30235634675` spent 10 minutes restoring a 2.13 GB SwiftPM cache and 19 minutes 19 seconds attempting a 1.62 GB Go cache restore, versus 2 minutes 25 seconds and 2 minutes 17 seconds for the respective runtime and Compose builds. Compose-only correction `6cae9a84` removes the release SwiftPM cache and disables release `setup-go` caching while retaining all validation-workflow caches. See [ISSUE-release-dependency-cache-overhead.md](container-compose/ISSUE-release-dependency-cache-overhead.md) and [PR-release-dependency-cache-overhead.md](container-compose/PR-release-dependency-cache-overhead.md). |
| [apple/container#1941](https://github.com/apple/container/issues/1941) | The supported fork ports the content-identical signal-name correction from [apple/container#1997](https://github.com/apple/container/pull/1997) in `bb2438c`, with regression coverage in `26cc778` and handoff details in [PR-1997.md](apple-container/PR-1997.md). Drop the port when Apple merges an equivalent fix. |
| [apple/container#1967](https://github.com/apple/container/issues/1967) | The supported `LogFileOutput` already retains complete records across backward-read chunks. Explicit 3 KB and multi-record tests in `26cc778` cover the behavior proposed by [apple/container#2000](https://github.com/apple/container/pull/2000). |
| [apple/container#2009](https://github.com/apple/container/issues/2009) | The supported init-process reattach path writes persistent sinks first and removes failed clients through `AttachableOutput`; `26cc778` proves later persistent writes continue. Apple main still needs its own reviewed fix. |
| [apple/containerization#798](https://github.com/apple/containerization/pull/798) | Merged upstream. Its SwiftPM manifest correction is included in the current Apple baseline, so it no longer needs fork-side review or a local port. |
| [apple/container#2021](https://github.com/apple/container/issues/2021) | Host disk-space retention after deleting guest files is owned by the macOS Virtualization.framework virtio-fs implementation and is released when the container stops. The supported stack must not add a divergent copy, remount, or guest-filesystem workaround for an Apple OS primitive. Track the upstream platform resolution. |
| [apple/container#2022](https://github.com/apple/container/issues/2022) | The reported long-line `logs -n` correctness case passes on the installed supported runtime with a 2,001-byte first record and exact final three records. The four reported hot-path inefficiencies reproduce in the fork and are corrected as independent signed commits: glob cache `abab498f` plus Unicode-semantics correction `4436afe`, hashed context membership `41e31f7`, concurrent stats `600fde2`, and off-lock disk sizing `b15ac4a`. Review follow-up `c7d05f1` keeps active-volume accounting consistent with the sizing snapshot. Matching issue/PR handoffs are linked above. |

## Open Follow-up

- Keep `apple/container#1934`, `#1935`, and `#1965`, `apple/containerization#799`, and `apple/container-builder-shim#87` open until Apple merges, replaces, or explicitly rejects their current changes.
- The 27 July refresh found those four Stephen-authored Apple pull requests
  mergeable with no actionable author review. The account-wide connector
  audit also confirmed that every actionable connector thread has a Stephen
  response; historical merged threads remain open until their current-main
  fix or verification is linked.
- Rebase `apple/container#1935` after `apple/container#1862` lands so the preferred upstream XPC commit is not duplicated.
- Generic log-retrieval runtime primitives still need minimal Apple proposals; Docker timestamp parsing remains owned by `container-compose`.
- [apple/container#378](https://github.com/apple/container/issues/378) needs a running-process stream reattach primitive before Compose can support interactive `attach`; the required runtime contract and the deliberate output-only fallback are documented in [ISSUE-attach-stream-reattach.md](apple-container/ISSUE-attach-stream-reattach.md).
- The container storage-boundary follow-up must wait for `apple/container#1735` and retain only its residual `FilePath` and volume-disk-usage protections. The independent `containerization` handoff is ready in [PR-container-storage-path-validation.md](apple-containerization/PR-container-storage-path-validation.md).
- The two builder-shim handoffs are independently constructible and have no matching open upstream issue or pull request. Keep them separate from [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87), which changes `.dockerignore` filtering only.
- The reporter's post-fix stop-interruption observation on [apple/containerization#799](https://github.com/apple/containerization/pull/799) is not a requested review change. Keep it under local macOS reproduction before widening the existing copy-failure proposal or opening a separate lifecycle fix.
- The connector review on
  [stephenlclarke/containerization#9](https://github.com/stephenlclarke/containerization/pull/9)
  identified that `LinuxPod` does not yet stage and rewrite a volume
  `sourceSubpath` like `LinuxContainer`. The author has acknowledged the
  actionable thread; retain it as a separate generic runtime follow-up with
  focused pod coverage rather than folding it into Compose CC-001.

## Submission Boundary

Never push to an Apple remote. Upstream imports stay in standalone commits with their original PR and bug references. Locally authored Apple-shaped changes must have focused tests and matching issue/PR handoffs in this directory before their `stephenlclarke` fork branches are proposed to Apple.
