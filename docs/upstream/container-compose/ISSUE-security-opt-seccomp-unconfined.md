# Support `security_opt: seccomp=unconfined` at the Compose boundary

## Problem

Docker Compose V2 retains and accepts `seccomp=unconfined` and
`seccomp:unconfined`, but the adapter
previously rejected every `security_opt` value other than the generic
no-new-privileges forms. The macOS guest workload baseline already runs
without a seccomp filter, so these equivalent options have a truthful local behavior
without requiring a Docker-shaped runtime no-op.

## Acceptance criteria

- Preserve both unconfined seccomp spellings in canonical config output.
- Accept it for managed services and one-off `compose run` before resources
  are created.
- Do not emit a synthetic `container --security-opt` argument for it.
- Preserve and forward any simultaneous no-new-privileges option.
- Continue rejecting seccomp profiles, AppArmor, SELinux, and arbitrary
  security-option strings before side effects.
- Prove Docker Compose V2 config parity with a Compose YAML fixture.

## Scope

This is Compose-layer behavior only. It does not add a runtime security
profile API, weaken an existing guest filter, or claim support for seccomp
profiles. The guest's existing workload baseline is unconfined; profile-based
security options still need an enforceable Apple runtime primitive.
