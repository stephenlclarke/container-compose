# Issue 306: update create-options parity for redacted dry-run logging values

## Problem description

The `docker-compose-create-options-parity` release check expected raw logging
option values in `container-compose --dry-run` output. Dry-run rendering now
deliberately redacts those values, so the product emitted the secure contract
while the stale release assertion stopped the 0.12.0 gate without explaining
which fragment was missing.

## Resolution

The parity check now requires the redacted logging-option form and rejects the
former raw values. Every dry-run fragment assertion reports the exact missing
or forbidden fragment instead of returning an unlabeled shell status.

## Focused evidence

- `bash -n Tools/parity/check-compose-create-options.sh`
- `Tools/parity/check-compose-create-options.sh --strict` against the exact
  matched Container release candidate

## Scope

This changes release evidence only. It does not alter Compose runtime behavior
or weaken the live create exercise performed by the same parity check.

Refs [#306](https://github.com/stephenlclarke/container-compose/issues/306).
