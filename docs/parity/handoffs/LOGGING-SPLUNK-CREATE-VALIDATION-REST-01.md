# LOGGING-SPLUNK-CREATE-VALIDATION-REST-01 Handoff

## State

`Blocked` — local signed Container commit `0679e82eaa15fee1c4699f1e3c74515040ed4a3f` implements the two Docker-required Splunk startup diagnostics, but the focused regression cannot execute from an immutable compatible dependency graph. It is not `Verified`, and no public-socket candidate has run.

## User-visible contract

The unmodified Docker CLI creates a `splunk` container even when `splunk-url` or `splunk-token` is absent, and inspect reports the configured driver while the container stays `created`. `docker start` then fails at logging-driver initialization: missing `splunk-url` reports `splunk-url is expected`; with a URL but no token it reports `splunk-token is expected`. Neither result may disclose a supplied token.

## Pinned Docker oracle

On this MBP, Docker CLI `29.7.1`, Engine `29.2.1` (API `1.53`), Colima, and `alpine:3.20` produced both observations. Each guarded unique-name probe created successfully, inspected its logging configuration, failed start with the exact driver-specific phrase, retained `created`, and removed only its own container. These are functional boundary observations; no performance comparison is asserted.

## Affected repositories and inputs

- Container source: branch `upstream/logging-driver-parity`, base `d67b614ebd7e0c1fade908c4a5ab6e48b751e393`, signed correction `0679e82eaa15fee1c4699f1e3c74515040ed4a3f`.
- Container `Package.resolved`: SHA-256 `c60ff0b8ae4dfac5ef80733453c273141a9070028e34d75d6afafc65a3147e53`; its resolved Containerization pin is `77f06d4c44341e04241941072fb69e2b85a6f5c1`.
- Compatible local diagnostic overlays were Containerization `ecb2ac5099a8521f02c248870fa6dd7aa7518465` and Engine API `8aa75ac5e42b0d0399f9ca7d48f0cfad00d3c711`. They were used only to identify the graph boundary; neither pin was changed or published.
- Container Compose records this evidence only; it has no source change for this slice.
- Guest/init image, candidate binary/archive, and disposable candidate root are N/A until the public-socket candidate is assembled. No dependency pin moved.

## Source correction and focused proof

`ContainerDockerLoggingBackend.map` formerly recognized the special GELF connection failure but reduced typed `SplunkProviderError` values to `container logging operation failed`. The correction maps only `missingURL` and `missingToken` to Docker-shaped messages; other Splunk failures retain the existing generic handling until their own oracle contracts are selected. `ContainerLoggingStartErrorTests` asserts both branches. `git diff --check` passed before commit.

The warmed `swift test --skip-build --filter ContainerLoggingStartErrorTests` ran a stale binary and omitted the new regression, so it is not evidence. The normal resolved graph failed before the test target because it lacks `WorkloadNetworkEndpoint`. A Containerization-only overlay then reached the next incompatible Engine API surface. With both compatible overlays, the isolated build compiled `ContainerDockerLoggingBackend.swift` but failed before test execution because `Tests/IntegrationTests/Containers/TestCLIExecCommand.swift` was modified during the build; its content still matched the committed blob, proving a timestamp mutation rather than a source change.

A second attempt used detached Container source `0679e82eaa15fee1c4699f1e3c74515040ed4a3f` and the same two overlays. It failed before test execution because `Sources/Containerization/HostDefaultRoute.swift` was modified during compilation. Its content hash and committed blob both remained `32785d7b7320733b430d8c5bf73f05d81f6d5ef8`, while its metadata changed on 8 August. This is the second evidence-based correction attempt defeated by a mutable input, so the validation loop stops here. No hang, timeout, or product liveness failure was observed; ordinary build duration is not a blocker. Whole-file SwiftFormat lint shows existing debt in the two surrounding files; no format waiver is claimed.

## Completion criteria

- Freeze one compatible Container, Containerization, and Engine API graph, prove all input SHAs and timestamps stable, then run the focused test successfully.
- Run a fresh marker-protected public Docker-socket candidate that binds source, dependency revisions, built binary, guest/init image, harness, and root in one fingerprint, then demonstrates both create/inspect/start/state/cleanup paths.
- Record focused changed-code coverage toward the 90% target.
- Treat a candidate hang, timeout, fingerprint mismatch, or cleanup failure as a functional blocker. Performance optimization and comparative timing remain a later phase.

## Safe handoff

The correction is clean and signed locally. [Container issue #92](https://github.com/stephenlclarke/container/issues/92) is open and must remain open until the completion evidence exists. The immediate unblock is a frozen compatible dependency graph, preferably immutable detached worktrees or published pins, followed by a new marker-protected test root and a fresh public-socket candidate. Do not push, create a PR, publish upstream, or report an Apple issue. The active slice START thread is `1786201895.827969`.
