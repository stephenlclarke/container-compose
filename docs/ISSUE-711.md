# Issue 711: finalize qualified Bazel Compose artifacts

[GitHub issue](https://github.com/stephenlclarke/container-compose/issues/711)

## Problem

The layered Compose workflow can qualify and publish a signed prerelease, but cannot finish the stable Homebrew release from those admitted bytes. The older stable path rebuilds the native stack and has a different release authority.

Add a narrow Bazel stable finalizer that preserves qualified executable bytes, supplements reviewed notices and source availability, notarizes the final distribution, publishes benchmark/parity provenance, verifies real GitHub downloads, tests the matched Homebrew formula pair with exact baseline restoration, and promotes the same immutable release. Keep qualification source and release-tooling commits distinct. Historical failed attempts must remain failed evidence.

Validation must include altered payload/source rejection, unknown notary/publication reconciliation, partial installation restoration, real downloaded installation tests, and unchanged lower artifact hashes. Heavy validation runs locally; existing exact-source GitHub code-quality results remain part of admission.

## Acceptance

A stable/latest immutable GitHub release must retain exact qualified executable bytes and current benchmark/parity provenance. The matched Container runtime must remain unchanged. Actual downloads, both Homebrew tests, full baseline restoration and atomic tested formula publication must pass before promotion.

## Scope

The release helpers and installation adapter complete the existing enhanced qualification. Runtime optimization and a new build-system migration are outside this release.

Implementation: [PR 712](https://github.com/stephenlclarke/container-compose/pull/712).

The actual Homebrew preflight exposed non-plist macOS login/background registrations. The pair adapter must preserve their available registration identity without requiring Homebrew-specific path/program fields; owned service lifecycle checks remain strict.

Installation correction: [PR 713](https://github.com/stephenlclarke/container-compose/pull/713).

The launchd list also includes per-user jobs that are absent from the GUI domain. The adapter now tries the per-user domain only after an explicit service-not-found response and records the successful domain as part of registration identity. Transport failures and absence in both domains still reject; three additional regressions cover this distinction.

Natural turnover of the exact system Spotlight shared-worker UUID instances is compared by its verified persistent definition. Every other registration retains exact identity checks. The adapter also retains private, bounded and redacted command diagnostics for failed Homebrew steps. All 32 focused installation/restoration/parser/diagnostic regressions pass; actual installation and restoration remain mandatory before stable promotion.

Actual Homebrew 7 audit rejected formula style and a redundant version stanza. Maintained templates now derive the unchanged distribution version from the release URL and pass current formatting requirements. The explicit owned-keg post-install checks retain a narrowly documented InstallSteps cop exception in the installation audit command (no in-formula disable directives) because the declarative DSL cannot express the required ownership/alias checks; registration behavior remains covered by Ruby regressions. Product archive/notarization assets remain unchanged.

Homebrew relocation can change installed Mach-O bytes and replace Developer ID signatures. Both stable Bazel formulas now restore only the 11 hash-pinned native files from their existing immutable release resources after relocation. Restoration checks every source and destination before mutation, uses exclusive owned temporary files and preserves the original notarized bytes. The adapter runs the actual public post-install step before binary checks, formula tests and owned plugin registration; six Ruby regression cases cover exact restoration, source corruption, symlinks, foreign temporary files, preflight ordering and escaping paths. Both formulas pass current Homebrew style (the documented InstallSteps exception only) and strict online content audits. The focused local Makefile test target passes all 79 Python cases and 11 Ruby cases (22 assertions).

The qualified runtime actually embeds additional build, source and dependency metadata in `--version`. Admission now parses unique metadata fields and still requires the exact embedded product version and qualified commit; the Homebrew test checks both independently. Actual installed binary hashes before post-install already matched the qualified archives. Spotlight application UUID instances are now bound to their exact verified system base definition alongside shared workers, while other jobs retain exact comparisons. Two additional regressions cover enriched/ambiguous version output and application-worker churn. All 81 Python and 11 Ruby cases pass.
