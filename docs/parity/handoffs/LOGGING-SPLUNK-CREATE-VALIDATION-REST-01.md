# LOGGING-SPLUNK-CREATE-VALIDATION-REST-01 Handoff

## State

`Verified` — the signed local Container correction and a clean, exact-fingerprint
public Docker-socket candidate reproduce both Docker-required Splunk startup
diagnostics. The candidate completed with exit code `0`; no hang, timeout,
fingerprint mismatch, or cleanup failure occurred.

## User-visible contract

The unmodified Docker CLI creates a `splunk` container even when `splunk-url` or `splunk-token` is absent, and inspect reports the configured driver while the container stays `created`. `docker start` then fails at logging-driver initialization: missing `splunk-url` reports `splunk-url is expected`; with a URL but no token it reports `splunk-token is expected`. Neither result may disclose a supplied token.

## Pinned Docker oracle

On this MBP, Docker CLI `29.7.1`, Engine `29.2.1` (API `1.53`), Colima, and
`alpine:3.20` produced both observations. Each guarded unique-name probe
created successfully, inspected its logging configuration, failed start with the
exact driver-specific phrase, retained `created`, and removed only its own
container. The retained oracle record is
`/private/tmp/container-rest-splunk-reference.Uy0c4u/result.json` (SHA-256
`6763ffe39c1daf5e23d4e137e103aab67d795b3a7a15374da0c7092cee335103`).
These are functional boundary observations; no performance comparison is
asserted.

## Affected repositories and inputs

- Container source: branch `upstream/docker-wait-acknowledgement-01`, signed
  correction `bf2d6de19e0924fa3cd08fe20276c987d785c060`
  (`fix(logging): restore Splunk start diagnostics`).
- Detached compatible inputs: Containerization
  `38d9c695e7a6915e5ce45d12c893dc323a661af7` and Engine API
  `afb8a8f68ed56829b669c95cbddb488a68dc9175`.
- Container Compose local `main` fixture checkpoint:
  `ec3c89b093d3894df3cc6b33c6ed04aa2ccd38a1`
  (`test(parity): add Splunk startup validation fixture`). No remote or
  dependency pin moved.
- Candidate package SHA-256: CLI
  `9e8f9a509cc1eb6defdcbbd590d690ddc16eedcbba3c8f3ff19ccbca75e47c11`,
  API server `e0fd8247295233357947fbce5fcfbdff8c858397bbc4091cf0fed28691b476fe`,
  engine `202ba2ab0e7dd910257fec455892f4db38bc37486a804c7e5ef5ab1da91ed89e`.
- Guest/init archive SHA-256:
  `5d4201135affb9bb0ce34ebcb184551689a214d3118b75564a8fa498667d77f6`;
  bootstrap archive SHA-256:
  `c714ab7421c71cebdfd0236c5a1af4b1e9af3da1855946cf3350a384491815f0`.

## Source correction and focused proof

`ContainerDockerLoggingBackend.map` restores typed
`SplunkProviderError.missingURL` and `.missingToken` to their Docker-shaped
messages, while leaving other Splunk failures on their existing generic path.
`ContainerLoggingStartErrorTests` now includes
`mapsMissingSplunkRequiredOptionsToDockerDiagnostics`; the exact detached graph
passed all seven tests in that suite. `git diff --check`, `bash -n`, and
ShellCheck passed before their respective signed checkpoints.

`Tools/parity/check-docker-rest-splunk-create-validation.sh` provides the
public CLI proof: it creates each invalid configuration, checks `splunk` in
inspect, asserts the exact start diagnostic and retained `created` state,
redacts the supplied token sentinel, and removes only its owned containers.
Its final exact-fingerprint run retained
`/private/tmp/ctr-splunk-create-validation-final.MZvMRd/`:
`FINGERPRINT-PREFLIGHT.json`, `FINGERPRINT-COMPLETE.json`, and
`fixture/result.json` record the inputs and exit `0`. The result contains both
expected diagnostics and `status: "passed"`.

Coverage instrumentation was attempted with the focused test but stopped before
completion when the Swift build graph reduced free disk space from about 11 GiB
to about 6 GiB. No coverage percentage is claimed. This is a non-functional
quality-evidence gap under the current performance policy, not a parity blocker;
the two changed diagnostic branches have direct focused tests.

## Completion criteria

- Met: the compatible source graph passed `ContainerLoggingStartErrorTests`.
- Met: the fresh marker-protected public Docker-socket candidate bound source,
  dependencies, binaries, guest/init archives, harness, and roots in one
  fingerprint, then demonstrated both create/inspect/start/state/cleanup paths.
- Remaining evidence gap: measure focused changed-code coverage toward the 90%
  target only when disk headroom permits a coverage-instrumented build.
- A future candidate hang, timeout, fingerprint mismatch, or cleanup failure is
  functional-blocking. Performance optimization and comparative timing remain a
  later phase.

## Safe handoff

The correction and fixture are clean signed local checkpoints. Preserve the
oracle and final candidate roots above until their evidence has been absorbed
into a broader immutable checkpoint. [Container issue #92](https://github.com/stephenlclarke/container/issues/92)
has functional completion evidence, but must not be commented on or closed
without explicit external-state authorization. Do not push, create a PR,
publish upstream, or report an Apple issue. The active slice START thread is
`1786217210.449779`.
