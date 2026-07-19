# Support `security_opt: apparmor=unconfined` at the Compose boundary

## Problem

Docker Compose V2 preserves and accepts `apparmor=unconfined`, while the
adapter rejected it with all unsupported profile names. The matched macOS Linux
guest has no usable AppArmor confinement interface for workload processes
(`/proc/self/attr/current` returns `EINVAL`), so an unconfined request is
truthful without adding a Docker-specific runtime no-op.

## Acceptance criteria

- Preserve `apparmor=unconfined` in canonical config output.
- Accept it for service `up` and one-off `run` before resources are created.
- Consume it in the Compose adapter rather than emitting a synthetic generic
  runtime flag.
- Continue forwarding no-new-privileges and consuming seccomp unconfined when
  both appear in the same list.
- Continue rejecting AppArmor profile names and all other unsupported
  security-option values before side effects.
- Compare the YAML fixture with Docker Compose V2 config output.

## Scope

This is macOS guest baseline compatibility, not AppArmor profile support. It
does not load policies, change a kernel LSM configuration, or claim Docker's
default AppArmor profile behavior. A generic, enforceable profile primitive is
still required before profile-based values can be supported.
