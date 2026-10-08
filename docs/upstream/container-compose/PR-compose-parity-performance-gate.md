# Pull request: run development parity and matched performance together

## Problem and behavior

The existing development parity target stopped after its 66 original strict
parity cases, while full qualification also ran hosted, unit, coverage,
notarization, and release checks. This adds a focused local target for a fresh
candidate that runs those 66 cases and the published-reference benchmark's
four one/three-service up/down fixtures with seven measured trials each.

## Implementation

- Add `make bazel-compose-development-parity-performance` and the matching
  `--development-parity-performance` controller option.
- Reuse the development parity package/test-product stage selection, exact
  Container checkout and receipt admissions, signed private plugin install,
  and existing host/runtime/Colima/command/project restoration path.
- Reuse the admitted published benchmark reference from the local asset cache;
  measure only the fresh candidate and compare all four seven-trial vectors to
  the retained Docker samples.
- Keep the existing `--development-parity` behavior and non-release receipt
  unchanged. Do not run hosted admission, the separate runtime test suite,
  notarization, or release preparation/publication.
- Document the target in the README and Bazel workflow guide.

## Validation

- Focused Python controller and CLI regressions cover the all-66 parity
  selection, exact four-fixture/seven-trial reference comparison, excluded
  release gates, and unchanged existing development parity behavior.
- Python lint and repository Markdown lint are required before merge.
- Live candidate/runtime validation is a separate authorized campaign step;
  no live result is claimed by this implementation handoff.

## Compatibility and risks

This changes only local qualification orchestration and evidence. It does not
change Compose command behavior or modify the published Docker reference.
The target is not release qualification; final release still requires the
complete hosted and local gates.

## Linked handoff

See [the companion issue](ISSUE-compose-parity-performance-gate.md).
