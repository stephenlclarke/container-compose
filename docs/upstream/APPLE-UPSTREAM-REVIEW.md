# Current Apple Upstream Review

This is the current disposition of Apple work that affects the five-repository container stack. Re-check GitHub before changing an Apple-backed component because issue, review, and merge state can change independently.

## Scope

- `apple/container`
- `apple/containerization`
- `apple/container-builder-shim`

## Open stephenlclarke Proposals

| Pull request | Current purpose |
| --- | --- |
| [apple/container#1933](https://github.com/apple/container/pull/1933) | Ready-for-review fix for [apple/container#1754](https://github.com/apple/container/issues/1754): implement SwiftLog event handlers and preserve existing output. |
| [apple/container#1934](https://github.com/apple/container/pull/1934) | Ready-for-review fix that preserves the complete `unspecified` version placeholder. |
| [apple/container#1935](https://github.com/apple/container/pull/1935) | Ready-for-review root-help responsiveness fix for [apple/container#1459](https://github.com/apple/container/issues/1459), stacked on [apple/container#1862](https://github.com/apple/container/pull/1862). |
| [apple/containerization#798](https://github.com/apple/containerization/pull/798) | Ready-for-review manifest fix that excludes the `CloudHypervisor` README from SwiftPM target inputs and removes the warning introduced with [apple/containerization#782](https://github.com/apple/containerization/pull/782). |
| [apple/containerization#799](https://github.com/apple/containerization/pull/799) | Ready-for-review fix for [apple/container#1927](https://github.com/apple/container/issues/1927): missing copy sources fail promptly, preserve the guest error, and no longer block later container lifecycle operations. |

## Ready Apple Handoffs

| Repository | Current purpose |
| --- | --- |
| `apple/container-builder-shim` | [Build-context source-read errors](apple-container-builder-shim/PR-build-context-source-read-errors.md) fail explicitly instead of sending empty file content. |
| `apple/container-builder-shim` | [Build-context cache integrity](apple-container-builder-shim/PR-build-context-cache-integrity.md) verifies archives, atomically publishes cache trees, and keeps synthetic Dockerfiles request-local. |

## Overlapping Upstream Work

| Pull request | Local disposition |
| --- | --- |
| [apple/container#1862](https://github.com/apple/container/pull/1862) | Preferred XPC cancellation implementation. Imported unchanged as the first standalone commit in `apple/container#1935`, with deterministic tests in the next commit. Drop the import when this PR lands. |
| [apple/container#1926](https://github.com/apple/container/pull/1926) | Its attached-exec disconnect cleanup is represented in `stephenlclarke/container`; its separate stop-timeout path still needs single-owner cleanup review. |
| [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87) | Its `.dockerignore` re-included-parent fix is represented by standalone commit `2778407`; the fork retains its staged-Dockerfile safeguard until the upstream shape lands. |
| [apple/container#1735](https://github.com/apple/container/pull/1735) | Preferred daemon entry-point ID validation. Imported as standalone commit `16ecfd5`; the broader residual bundle-path and volume-disk-usage hardening is tracked in [PR-container-storage-path-validation.md](apple-container/PR-container-storage-path-validation.md) and must follow this PR rather than compete with it. |

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
| [apple/container#1937](https://github.com/apple/container/issues/1937) | Directory bind mounts containing hardlinks can intermittently fail with `EACCES` inside the guest. The single-file hardlink fix from [apple/containerization#665](https://github.com/apple/containerization/pull/665) is already present, but this report covers directory bind-mount semantics, so `container-compose` must not paper over it with a copy/snapshot workaround that would break live bind behavior. |

## Open Follow-up

- Keep `apple/container#1933`, `#1934`, `#1935`, `apple/containerization#798` and `#799`, and `apple/container-builder-shim#87` open until Apple merges, replaces, or explicitly rejects their current changes.
- Rebase `apple/container#1935` after `apple/container#1862` lands so the preferred upstream XPC commit is not duplicated.
- Generic log-retrieval runtime primitives still need minimal Apple proposals; Docker timestamp parsing remains owned by `container-compose`.
- The container storage-boundary follow-up must wait for `apple/container#1735` and retain only its residual `FilePath` and volume-disk-usage protections. The independent `containerization` handoff is ready in [PR-container-storage-path-validation.md](apple-containerization/PR-container-storage-path-validation.md).
- The two builder-shim handoffs are independently constructible and have no matching open upstream issue or pull request. Keep them separate from [apple/container-builder-shim#87](https://github.com/apple/container-builder-shim/pull/87), which changes `.dockerignore` filtering only.

## Submission Boundary

Never push to an Apple remote. Upstream imports stay in standalone commits with their original PR and bug references. Locally authored Apple-shaped changes must have focused tests and matching issue/PR handoffs in this directory before their `stephenlclarke` fork branches are proposed to Apple.
