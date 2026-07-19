# Map unconfined system paths through the generic guest runtime control

## Problem

Docker Compose V2 accepts `security_opt` values in both
`systempaths=unconfined` and `systempaths:unconfined` forms. The Compose
adapter previously rejected both values, even though the macOS Linux guest can
implement their OCI meaning without exposing a macOS host boundary.

The matching `container` fork now exposes a narrow generic control that clears
the Linux guest OCI masked/read-only path overrides. Compose needs to own only
the Docker-shaped parsing and spelling normalization at its boundary.

## Acceptance criteria

- Preserve both spellings in canonical `config` output.
- Translate either spelling to one generic
  `--security-opt systempaths=unconfined` runtime argument.
- Keep it independent of Linux capabilities and no-new-privileges.
- Retain pre-side-effect errors for unsupported profile and label requests.
- Add focused adapter, normalizer, matched-guest runtime, and Docker Compose
  V2 YAML parity coverage.
- Update the runtime status ledger without changing the Compose command/help
  surface, because this is a service-field capability rather than a new CLI
  option.

## Scope

On macOS this affects only the Linux guest's OCI masked/read-only path lists.
It does not grant host access, add Linux capabilities, load a security profile,
or implement Windows security-option forms.
