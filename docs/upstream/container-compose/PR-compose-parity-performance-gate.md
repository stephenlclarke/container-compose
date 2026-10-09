# Pull request: run development parity and matched performance together

## Problem and behavior

The existing development parity target stopped after its 66 original strict
parity cases, while full qualification also ran hosted, unit, coverage,
notarization, and release checks. This adds a focused local target for a fresh
candidate that runs those 66 cases, the published-reference benchmark's four
one/three-service up/down fixtures with seven measured trials each, and the
complete 29-fixture lifecycle/logging matrix for five counterbalanced
Docker/candidate repetitions, including remote logging.

## Implementation

- Add `make bazel-compose-development-parity-performance` and the matching
  `--development-parity-performance` controller option.
- Reuse the development parity package/test-product stage selection, exact
  Container checkout and receipt admissions, signed private plugin install,
  and existing host/runtime/Colima/command/project restoration path.
- Reuse the admitted published benchmark reference from the local asset cache;
  measure only the fresh candidate and compare all four seven-trial vectors to
  the retained Docker samples.
- Before the first full-suite case, run a read-only Buildx availability check
  against the selected Docker config and Colima context, then retain its exact
  version and selected-plugin hash. Fail before any case if Docker would fall
  back to a different builder.
- Run the existing broad matrix directly inside the same runtime, host,
  Colima, and command leases, without its build prerequisite or runtime
  wrapper. Apply identical 200 MiB hard service limits to lifecycle and
  aggregate fixtures in both lanes. Capture exact fixture hashes and a fresh
  host/Colima/memory-pressure capacity receipt before timing.
- Reject a 50-service run before launch if physical allocation budgets or
  current reclaimable memory do not satisfy the explicit guest envelope and
  host-headroom limits. Preserve the matrix's real functional and timing
  failures in the controller receipt.
- Take cleanup snapshots with the lane's own CLI. The candidate uses native
  `list --all --format json`, `network list --quiet`, and `volume list --quiet`
  commands, then validates and sorts native container IDs/names through the
  full-suite parser. The Docker control lane uses `docker --context colima ps
  -aq`, `network ls -q`, and `volume ls -q`. This prevents Docker-only `ps`
  flags from being sent to the native Container CLI; it changes no product
  command or compatibility assertion.
- Keep the existing `--development-parity` behavior and non-release receipt
  unchanged. Do not run hosted admission, the separate runtime test suite,
  notarization, or release preparation/publication.
- Document the target in the README and Bazel workflow guide.

## Validation

- Focused Python controller and CLI regressions cover the all-66 parity
  selection, exact four-fixture/seven-trial reference comparison, bounded
  matrix fixture selection and workload fingerprints, Buildx identity and
  missing-plugin rejection before any parity case, cleanup admission, excluded
  release gates, and unchanged existing development parity behavior.
- The three focused cleanup-inventory regressions pass: command selection for
  both lanes, resource snapshot normalization using a fake runner, and rejection
  of duplicate native container identities.
- Python lint and repository Markdown lint are required before merge.
- Fresh source-1ef validation passed 66 parity fixtures, 27 native runtime
  tests from the retained 5a artifact (its test source and fixture bundle match
  the current source), and the four-fixture/seven-trial comparison (28 fresh
  samples against 28 historical samples). The broad matrix passed 260 samples for 26
  fixtures using the bounded 4-GiB profile and 200-MiB service cap. The three
  50-service fixtures (30 planned samples) were not started: the unchanged
  fail-closed guard recorded 5.556 GiB available against 9.328 GiB required.
  They remain pending, not measured failures or successes. The 8-GiB
  comparison and 4-GiB matrix measurements remain separate; cleanup and host
  restoration were independently verified.

## Compatibility and risks

This changes only local qualification orchestration and evidence. It does not
change Compose command behavior, add Docker-only CLI flags to Container, or
modify the published Docker reference. The incomplete 50-service matrix means
the full 29-fixture performance scope is still pending. This target is not
release qualification; final release still requires the complete hosted and
local gates.

## Linked handoff

See [the companion issue](ISSUE-compose-parity-performance-gate.md).
