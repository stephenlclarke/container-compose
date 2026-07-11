# Vminitd Exec Logging Exposes Environment Secrets

## Upstream Reference

- Existing report: [apple/containerization#518](https://github.com/apple/containerization/issues/518)

Do not open a duplicate issue.

## Problem

`ManagedContainer.createExec` interpolates the complete OCI process
configuration into a debug message. The generated description includes every
environment entry, so credentials supplied to a workload or exec process can
appear in the guest boot log.

## Expected Behavior

- Exec creation logs contain only operational identifiers.
- OCI process arguments, environment, capabilities, and user data are not
  serialized into logs.
- Container and exec IDs remain available for correlation.

## Ownership

This is a `containerization` guest-agent security fix. Callers must not need to
redact boot logs after secrets have already been written.
