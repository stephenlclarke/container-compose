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
