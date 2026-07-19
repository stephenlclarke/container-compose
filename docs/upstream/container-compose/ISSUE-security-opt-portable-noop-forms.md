# Support portable no-op security-option forms on the macOS guest

## Problem

Docker Compose permits both `option=value` and `option:value` forms for
security options, and bare `no-new-privileges` means enabled. The adapter had
implemented only a subset of those spellings and rejected `label=disable`,
even though the macOS Linux guest has no SELinux label to apply and no seccomp
or AppArmor workload profile to relax.

## Acceptance criteria

- Normalize bare `no-new-privileges` to the generic explicit true argument.
- Accept both unconfined seccomp and AppArmor spellings as Compose-layer
  no-ops.
- Accept `label=disable` and `label:disable` as a Compose-layer no-op.
- Preserve each original spelling in canonical config output.
- Reject values that request an enforceable profile or label before side
  effects.
- Exercise the values together in a Docker Compose V2 YAML parity fixture.

## Scope

The no-op values are limited to the existing macOS guest baseline. This does
not add SELinux labeling, AppArmor policy loading, seccomp filters, a default
Docker security profile, or host-security behavior.
