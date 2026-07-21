# Compose must retain runtime support for equals-valued labels

## Problem

Compose service labels may legitimately contain `=` in their values. Compose
already models them as a dictionary, but its supported runtime revision must
include the matching generic Container parser behavior for CLI and shared
runtime consistency. The Docker Compose v2 parity fixture previously exercised
only a simple label value.

## Scope and boundary

`container-compose` owns the dependency pin and Compose-file parity coverage.
`apple/container` owns the generic first-separator label parser. No Compose
syntax, runtime abstraction, or Docker-specific fallback is added to the Apple
fork.

## Required behavior

- Compose resolves the Container fix at its immutable stack revision.
- Docker Compose v2 configuration and Compose dry-run output retain an exact
  label value containing `=`.
- Same-key OCI annotations remain distinct from labels.

## Commit tracking

- `b48711cb344434a3a2b2cbf301953cd5a40d2f4c` —
  `fix(labels): preserve equals-valued labels`
- Dependency: `stephenlclarke/container`
  `47c13a8ad0bf001fb569a17e73e2e3b8d4e45dff`

## Validation expectations

- Stack consistency accepts the revised Container pin.
- Docker Compose v2 parity covers configuration and dry-run output with the
  nested label value.
