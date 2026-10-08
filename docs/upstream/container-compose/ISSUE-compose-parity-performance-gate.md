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
compiled dependency chain, then runs all 66 parity cases, the canonical
four-fixture/seven-trial comparison against the existing published Docker
reference, and the full 29-fixture/five-repetition lifecycle and logging
matrix, including remote-sink lanes. Keep candidate installation, runtime
ownership, cleanup, and host restoration within the existing qualification
controller. The resulting receipt must remain explicitly non-release
evidence.

## Compose compatibility impact

Internal implementation and contributor workflow. No Compose behavior or
Docker Compose compatibility assertion changes.

## Acceptance

- The new Make target selects all 66 original parity cases, four matched
  one/three-service up/down fixtures with seven measured candidate trials
  each, and all 29 broad matrix fixtures for five counterbalanced repetitions
  on both lanes, including remote logging.
- The matrix uses an explicitly bounded profile with identical 200 MiB hard
  service limits in both lanes for lifecycle and aggregation fixtures; raw
  fixture hashes and the profile are retained as new evidence, separate from
  historical uncapped results.
- Before any 50-service workload, admission records and verifies the physical
  host, configured Colima allocation, candidate guest envelope, host
  headroom, and current reclaimable-memory estimate; insufficient capacity
  fails before the matrix starts.
- It admits the current clean Compose source, exact Q source/evidence, released
  Q asset hashes, compiled dependency chain, candidate package, and published
  benchmark reference.
- It uses the existing host, runtime, plugin, Colima, command, project, and
  restoration leases.
- It skips hosted quality, the separate runtime suite, unit/coverage replay,
  notarization, and release preparation/publication.
- The existing development parity command remains unchanged.
- The existing broad matrix command remains uncapped by default; the new
  bounded profile is selected only by the development performance gate.
