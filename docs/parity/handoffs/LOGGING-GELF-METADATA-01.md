# LOGGING-GELF-METADATA-01 Handoff

## State

`Verified`

## Verified behavior

The direct same-MBP Docker Engine 29.2.1/API 1.53 GELF metadata oracle is captured in [`docker-engine-29.2.1-gelf-metadata.json`](../../../Tests/ComposeCoreTests/Fixtures/logging/docker-engine-29.2.1-gelf-metadata.json). It proves the selected `env`/`env-regex` and `labels`/`labels-regex` union, environment precedence, a selected `container_id` overriding Docker's builtin field, `{{.Name}}/{{.ID}}` rendering, inspect preservation, UDP delivery, cleanup, and deferred invalid tag/RE2 failures.

The current direct comparison passed in 3.225985 seconds, 1.05× the captured baseline. Its exact Compose source, script/fixture hashes, Docker CLI/Engine/guest/image fingerprint, and machine-readable result are under `/private/tmp/container-gelf-metadata-runtime.9yKJCm` with the marker file `.container-gelf-metadata-runtime-root`.

## Component proof

An isolated SwiftPM editable-dependency overlay retains the exact local `containerization` and `container-engine-api` identities while supplying their recorded paths: Container `259878a427de7021b52e40e759d3b261150cc514`, Containerization `38d9c695e7a6915e5ce45d12c893dc323a661af7`, and Engine API `4949e743675f00ec102f7acacdb4e990409e383f`. `swift test --disable-automatic-resolution --scratch-path /private/tmp/container-gelf-metadata-overlay.lDcAcV/swift-build-editable --filter GELFConfigurationTests` passed 7/7 tests. The marker-protected root `/private/tmp/container-gelf-metadata-overlay.lDcAcV` records its dependency graph, build fingerprint, and test result.

## Applied regression

The formerly deferred additive provider regression is now committed in the local Container repository as `f3662f2f69d7af31e851b69fec07f51b63eb75dc`: it asserts Docker-matched rejection of an unresolved tag template, RE2 lookahead, and an invalid metadata regular expression. The production source is byte-identical to the tested worktree copy.

## Boundary

This closes only the direct Docker-reference and provider-component metadata contract. It does not certify a candidate runtime, public socket, external clients, devcontainer/Testcontainers adoption, cloud/plugin drivers, or the broader failure/migration/security/performance matrix.
