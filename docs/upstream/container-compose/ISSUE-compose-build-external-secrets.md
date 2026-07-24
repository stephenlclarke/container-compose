# Phase 5: resolve external build secrets through the macOS secure-store adapter

## Problem

Top-level external secrets already use the Compose-owned
`ComposeRuntimeSecretReading` SPI and the caller's macOS Keychain for service
mounts. A build grant referencing the same external resource was rejected
during normalization, even though the generic Apple Builder accepts a regular
file-backed BuildKit secret.

Docker Compose V2 5.3.1 establishes three observable local-mode behaviors:

1. `config` retains the top-level external definition and build grant.
2. `build --print` omits the external secret from bake JSON.
3. A required live BuildKit secret fails with `secret <id>: not found` because
   the local Docker engine has no external secret store.

Rejecting the model prevents the existing macOS secure-store extension from
supplying a feasible Apple build, while forwarding the Keychain account or
bytes through bake output or command arguments would expose secret metadata or
material.

## Required Compose-owned change

- Preserve the resolved external resource name in the normalized build-secret
  model without reading its contents.
- Keep `build --print` aligned with Docker Compose V2 by omitting the external
  secret.
- For a non-dry-run Apple build, read the resource through
  `ComposeRuntimeSecretReading`.
- Write the bytes to a unique invocation-private directory with 0700 directory
  and 0400 file permissions.
- Pass only the opaque file path to the generic
  `container build --secret id=...,src=...` primitive.
- Delete the invocation directory on success, command failure, reader failure,
  or validation failure.
- Keep dry-run behavior side-effect free.

No Container, Containerization, Builder, or Windows change is required.
Swarm secret drivers are not a local macOS Compose primitive.

## Acceptance

- Go and Swift normalization tests cover external `name:` plus build `target:`.
- Unit tests inspect the staged bytes and permissions while the engine command
  is active, then prove the file is absent after it returns.
- Unit tests prove dry-run performs no secure-store read or filesystem write.
- Unit tests prove reader errors occur before an engine command.
- Docker Compose V2 and `container compose` retain the same external model and
  omit it from bake output.
- A real Docker file-backed reference build and a real Keychain-backed Apple
  build use the same Compose fixture and Dockerfile.
- Full test, coverage, formatting, lint, security, documentation, and
  prerelease gates pass.
