# Pull Request

## Summary

Enhanced Compose previously required the vendor Engine gateway even though its compiled runtime calls the native Container API. Readiness now follows the compiled backend: native builds require a live matching API-server health row; Engine builds retain `container system status`.

## Type of Change

- [x] Bug fix
- [x] Documentation update

## Motivation and Context

[Issue details](ISSUE-native-api-readiness.md) describe the isolated devcontainer E13 failure before container creation. The runtime owner intentionally supplies a private API service without the unscoped vendor gateway.

The existing enhanced compile flag selects both `ComposeContainerRuntime` and native readiness. Runtime-profile environment metadata cannot select readiness or bypass enhanced client provenance. Native validation requires exactly one CLI and API row, full 40-character lowercase hexadecimal matching commits even without concrete package pins, valid server version/build fields, and the existing package pins, fork provenance, Containerization and capability checks. It uses only fields actually emitted by the health response; API-row provenance fields absent from that wire contract are not invented. Version strings need not match numerically across products. The decoded health row proves a bounded live API response, not complete runtime session ownership.

## Testing

- [x] Added/updated deterministic compatibility and readiness tests.
- [x] Added/updated installation and README documentation.
- [x] Focused local compatibility/readiness tests: both stock and enhanced pass 44 test functions in 6 suites against the final typed-selection source; the original 43-function proof is retained below.
- [ ] Release-owner validation of the corrected exact Compose asset in isolated E13.

Original native-readiness implementation evidence uses the repository-owned Bazel launcher and its cached debug source graph, with only `ComposePluginTests` and the compatibility/readiness filter selected:

| Profile | Invocation | Suite / target duration | Result |
| --- | --- | --- | --- |
| Enhanced | `15593a6b-de47-4420-b309-35a9d5e96803` | 2.013s / 2.9s | 43 functions in 6 suites passed |
| Stock | `5b97ba6a-646b-4d5a-adad-67f9c267fa6f` | 1.808s / 2.6s | 43 functions in 6 suites passed |

Retained launcher evidence is under `/Volumes/SSD/cf/bazel/invocations/compose-20261002T081056Z-89320` and `compose-20261002T081142Z-89918`. Strict SwiftLint, SwiftFormat, scoped Markdown lint and `git diff --check` pass. An initial optimized prebuilt-SDK attempt did not execute tests because release modules are not compiled for `@testable` imports; the final focused proof uses the supported debug source graph. No binary layer was rebuilt or published.

Both compiled backend policies are exercised through the internal test injection. Matching native health must never invoke `system status`; missing, duplicate, malformed and mismatched API identity fails before capabilities are published. Existing Engine status failure/cancellation checks remain selected. Offline commands skip runtime checks; native interruption propagation retains conventional signal status.

## Compatibility and Risks

This changes only preflight. No runtime lifecycle, socket, namespace, transport, signing or publication action is introduced. Native builds now reject a stock metadata override, unknown/unspecified live source identity, and ambiguous system-version rows. Stock Engine readiness remains unchanged. The corrected Compose product must be released and consumed as an exact asset before the devcontainer release can be verified; lower-layer assets are reusable where their identity is unchanged.

## container-compose Checks

- [x] Current support change recorded in `docs/upstream/`.
- [x] Focused on one coherent admission correction.
- [x] Runtime review notes included; root owns release and live evidence.
- [ ] Signed Conventional Commit and user-facing release-note trailer: deferred to the release owner.
- [x] No credentials or private runtime data included.

## Hosted Quality Integration Follow-up

The implementation plus registry head `2610b0fa51ef0b6243ff88556a6cf26c990e611e` passed both hosted unit/coverage profiles and Sonar analysis `15670e2f-abb3-4769-bbaf-790d0b5584cc` with quality status `OK` and no unreviewed PR/project hotspots. Validate Runtime still failed its stricter zero-unresolved-PR-issues check: `swift:S107`, issue `AaD72R_v78bo7UMLlcqE`, rejected the eight-parameter async preflight boundary. No runtime fixture failed.

The boundary now has seven parameters. `RuntimeSelection` groups requested metadata profile and the actual compiled/injected backend, retaining independent selection semantics. The production caller uses the same default as before; all explicit asynchronous test callers use the typed selection. A new regression exercises default production selection in both builds. No rule waiver, readiness weakening, environment bypass or new transport is introduced.

Focused correction evidence is recorded below. Root review, commit, publication and a fresh exact-head hosted Sonar analysis remain pending; the local arity check is not a replacement for that analysis.

- [x] Strict SwiftLint and SwiftFormat on touched Swift source/tests.
- [x] Static maximum-seven parameter check, counting default parameters; original source fails at eight, corrected source passes.
- [x] Final focused stock/enhanced compatibility results: 44 test functions in 6 suites pass in each build.
- [ ] New exact-head hosted Sonar analysis confirms `swift:S107` is resolved.

| Correction profile | Invocation | Suite / target duration | Result |
| --- | --- | --- | --- |
| Enhanced | `3b0e8053-e3fe-4fb3-9ee9-8948ca5cf0bc` | 2.027s / 3.0s | 44 functions in 6 suites passed |
| Stock | `76e7790a-338b-42a7-81ea-a422d8218209` | 1.753s / 2.5s | 44 functions in 6 suites passed |

The correction uses the same repository launcher, debug cached-source target and compatibility/readiness filter as the original proof. Exact raw logs and arity-before/after evidence are retained under `R/native-compose-2610b0fa/hosted-runtime-triage` in the release-owner handoff. Scoped Markdown lint and `git diff --check` pass.
