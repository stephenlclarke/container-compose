# LOGGING-GELF-METADATA-01 Handoff

## State

`Blocked`

## Completed reference behavior

The direct same-MBP Docker Engine 29.2.1/API 1.53 GELF metadata oracle is captured in [`docker-engine-29.2.1-gelf-metadata.json`](../../../Tests/ComposeCoreTests/Fixtures/logging/docker-engine-29.2.1-gelf-metadata.json). It proves the selected `env`/`env-regex` and `labels`/`labels-regex` union, environment precedence, a selected `container_id` overriding Docker's builtin field, `{{.Name}}/{{.ID}}` rendering, inspect preservation, UDP delivery, cleanup, and deferred invalid tag/RE2 failures.

The current direct comparison passed in 3.273304 seconds, 1.06x the captured 3.078461-second baseline. Its exact source/dependency/runtime fingerprint and machine-readable result are under `/private/tmp/container-gelf-metadata-evidence.T3A4SC` with the marker file `.codex-gelf-metadata-root`.

## Blocker

The required current `GELFConfigurationTests` component execution cannot obtain the recorded local Container `259878a427de7021b52e40e759d3b261150cc514`, Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`, and Engine API `4949e743675f00ec102f7acacdb4e990409e383f` graph from a clean SwiftPM root. With automatic resolution disabled, SwiftPM selected remote Container `2a79b4553a342e33411666a88ad20ccd2ce46551` and failed to read that tree. The direct Container attempt instead selected released Engine API 0.3.5; automatic resolution began selecting newer remote revisions and was stopped before a test ran. No further resolver retry is authorised without changing the resolution mechanism.

## Preserved candidate test

The unvalidated, additive provider test is preserved as [`LOGGING-GELF-METADATA-01-container-provider-test.patch`](LOGGING-GELF-METADATA-01-container-provider-test.patch), SHA-256 `c66cf598c07daec436ca73044f42a2dba9ef0d32a5f20385a135eaa722eff1a9`. It was removed from the Container checkout, which is clean. Apply it only after confirming that it is not duplicated by the resolved source revision.

## Resume point

Create an isolated SwiftPM graph whose package identities resolve only to the three recorded local paths, verify the package revisions and build product fingerprint before execution, apply the deferred test if still useful, and run the exact focused component regression. Then update the slice ledger with its result; do not treat the direct Docker reference fixture as candidate-runtime certification.
