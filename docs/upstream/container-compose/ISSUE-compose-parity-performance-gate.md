# Fresh local parity and benchmark gate without release replay

## Feature or enhancement request

The existing development parity command runs the 66 original strict parity
cases but does not run the published-reference performance comparison. The
full qualification command includes both, but also repeats hosted admission,
unit and coverage stages, notarization, and release checks. This makes it
costly to obtain a fresh, reviewable local candidate result for parity plus
performance after a clean source checkpoint.

Add a development-only Make target that creates and signs a candidate from the
current clean source using the admitted Container checkpoint and retained
compiled dependency chain, then runs all 66 parity cases and the canonical
four-fixture, seven-trial benchmark against the existing published Docker
reference. Keep candidate installation, runtime ownership, cleanup, and host
restoration within the existing qualification controller. The resulting
receipt must remain explicitly non-release evidence.

## Compose compatibility impact

Internal implementation and contributor workflow. No Compose behavior or
Docker Compose compatibility assertion changes.

## Acceptance

- The new Make target selects all 66 original parity cases and four matched
  one/three-service up/down fixtures with seven measured candidate trials each.
- It admits the current clean Compose source, exact Q source/evidence, released
  Q asset hashes, compiled dependency chain, candidate package, and published
  benchmark reference.
- It uses the existing host, runtime, plugin, Colima, command, project, and
  restoration leases.
- It skips hosted quality, the separate runtime suite, unit/coverage replay,
  notarization, and release preparation/publication.
- The existing development parity command remains unchanged.
