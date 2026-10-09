# Native Compose preflight incorrectly requires the vendor Engine gateway

## Steps to reproduce

1. Use enhanced Compose 0.15.1 built from `81a2263`, with its matching Container and Containerization pins.
2. Start the private native API service owned by devcontainer without the unscoped vendor Engine gateway.
3. Run the isolated devcontainer E13 Compose foreground-start case.

## Problem description

Installed package admission succeeds, but preflight then runs `container system status`, which requires the vendor gateway at its fixed launchd identity and `/tmp/docker.sock`. The enhanced Compose product uses direct Container APIs and does not consume that gateway. The command therefore fails before creating a provider container despite a live matching native API service.

Readiness must follow the compiled runtime backend. Native preflight should accept exactly one live matching API-server row emitted by the existing bounded system-version health ping; absent, duplicate, malformed or mismatched identity must fail closed. Engine products must retain their Engine readiness gate. Runtime-profile metadata must never switch the compiled transport or admit incompatible client provenance.

## Environment

- OS: macOS on the local MBP.
- container-compose: release 0.15.1; correction starts from `b84df4eb720df466f6d3abffd618c9bf4433aa7e` in the Bazel workflow checkout.
- Runtime: devcontainer-owned private native API/helpers; vendor gateway intentionally excluded.
- Failure phase: before provider-container creation; the failed claim is retained by the release owner.

## Scope and validation

This correction changes Compose admission only. It adds no gateway startup, bypass, transport, environment normalization, resource creation or release action. Focused deterministic tests cover backend selection, no-gateway native success, live identity failures, package/capability checks, offline exemptions and interruption propagation. Docker behavior and complete session fingerprint admission remain owned by the existing release/runtime gates.

## Linked work

- [Pull-request details](PR-native-api-readiness.md).

## Hosted Quality Integration Follow-up

CI run `36985804843` at implementation plus registry head `2610b0fa51ef0b6243ff88556a6cf26c990e611e` passed enhanced and stock unit/coverage gates and the Sonar quality gate. Its exact PR-admission step nevertheless failed because Sonar issue `AaD72R_v78bo7UMLlcqE` (`swift:S107`) found eight parameters at `ContainerPackageCompatibility.compatibilityFailure`; the permitted limit is seven. This is a maintained-source quality defect introduced by the backend test injection, not a runtime fixture failure.

The correction groups requested compatibility profile and compiled/injected backend in one typed `RuntimeSelection`. The default backend still comes from the build flag; environment metadata cannot select a transport. Native health identity, Engine readiness, package/capability admission, offline exemptions and interruption propagation are unchanged. A regression invokes the same omitted-selection default as the production caller in both builds. Root owns the reviewed follow-up commit and new exact-head hosted analysis; the failed `2610b0fa` evidence remains retained.
