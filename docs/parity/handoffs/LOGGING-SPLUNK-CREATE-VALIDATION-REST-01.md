# LOGGING-SPLUNK-CREATE-VALIDATION-REST-01 Handoff

## State

`Implemented` — local signed Container commit `0679e82eaa15fee1c4699f1e3c74515040ed4a3f` restores the two Docker-required Splunk startup diagnostics. It is not `Verified`: the targeted SwiftPM invocation was stopped before it reached the test target, and there is no public-socket candidate yet.

## User-visible contract

The unmodified Docker CLI creates a `splunk` container even when `splunk-url` or `splunk-token` is absent, and inspect reports the configured driver while the container stays `created`. `docker start` then fails at logging-driver initialization: missing `splunk-url` reports `splunk-url is expected`; with a URL but no token it reports `splunk-token is expected`. Neither result may disclose a supplied token.

## Pinned Docker oracle

On this MBP, Docker CLI `29.7.1`, Engine `29.2.1` (API `1.53`), Colima, and `alpine:3.20` produced both observations. Each guarded unique-name probe created successfully, inspected its logging configuration, failed start with the exact driver-specific phrase, retained `created`, and removed only its own container. These are functional boundary observations; no performance comparison is asserted.

## Affected repositories and inputs

- Container source: branch `upstream/logging-driver-parity`, base `d67b614ebd7e0c1fade908c4a5ab6e48b751e393`, signed correction `0679e82eaa15fee1c4699f1e3c74515040ed4a3f`.
- Container `Package.resolved`: SHA-256 `c60ff0b8ae4dfac5ef80733453c273141a9070028e34d75d6afafc65a3147e53`.
- Container Compose records this evidence only; it has no source change for this slice.
- Guest/init image, candidate binary/archive, and disposable candidate root are N/A until the public-socket candidate is assembled. No dependency pin moved.

## Source correction and focused proof

`ContainerDockerLoggingBackend.map` formerly recognized the special GELF connection failure but reduced typed `SplunkProviderError` values to `container logging operation failed`. The correction maps only `missingURL` and `missingToken` to Docker-shaped messages; other Splunk failures retain the existing generic handling until their own oracle contracts are selected. `ContainerLoggingStartErrorTests` asserts both branches. `git diff --check` passed before commit.

The command `swift test --disable-automatic-resolution -Xswiftc -warnings-as-errors --filter ContainerLoggingStartErrorTests` was started from this exact source graph. After a seven-minute cap it had not emitted test execution, only built the large local dependency graph, so it was interrupted. This is not passing test evidence. Whole-file SwiftFormat lint shows existing debt in the two surrounding files; no format waiver is claimed.

## Completion criteria

- Run the focused test successfully from the exact source graph.
- Run a fresh marker-protected public Docker-socket candidate that binds source, dependency revisions, built binary, guest/init image, harness, and root in one fingerprint, then demonstrates both create/inspect/start/state/cleanup paths.
- Record focused changed-code coverage toward the 90% target.
- Treat a candidate hang, timeout, fingerprint mismatch, or cleanup failure as a functional blocker. Performance optimization and comparative timing remain a later phase.

## Safe handoff

The correction is clean and signed locally. [Container issue #92](https://github.com/stephenlclarke/container/issues/92) is open with an implementation comment and must remain open until the completion evidence exists. Do not push, create a PR, publish upstream, or report an Apple issue. The completed slice START thread is `1786201083.483769`.
