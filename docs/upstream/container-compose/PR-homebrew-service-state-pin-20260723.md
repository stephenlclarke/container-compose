# Pull request handoff: consume the Container formula smoke fix

## Proposed pull request

`build(deps): consume Homebrew smoke fix`

This handoff covers the signed source commit
[`cf9aa1b75292645736a06ccef7f1a786a923d67d`](https://github.com/stephenlclarke/container-compose/commit/cf9aa1b75292645736a06ccef7f1a786a923d67d).

## Summary

Advance the exact Container package and release pin to the reviewed
service-independent Homebrew formula smoke. No runtime executable behavior or
Compose policy changes.

## Minimal integration boundary

- Changes only the existing immutable Container revision in the Swift package
  manifest, lockfile, and stack-release manifest.
- Keeps the Containerization and builder-shim revisions unchanged.
- Leaves the already-published `0.8.0` artifact pair immutable.
- Sources future stable and Current Container formulae from the corrected
  Container template.
- Keeps all Compose behavior above the existing runtime abstraction boundary.

## Code map

- `Package.swift`
  - resolves Container at `5de53c9b`.
- `Package.resolved`
  - records the same immutable Container revision.
- `Tools/release/stack-refs.json`
  - binds release packaging to the reviewed Container tip.
- `README.md`
  - updates the current support-fork revision and divergence count.
- `docs/upstream/container-compose/ISSUE-homebrew-service-state-pin-20260723.md`
  - records reproduction, correction, stable installation, and release
    evidence boundaries.
- `docs/upstream/container-compose/PR-homebrew-service-state-pin-20260723.md`
  - provides this handoff.

## Validation on macOS

```console
swift package resolve
make stack-consistency coverage-tools-test check
brew test stephenlclarke/tap/container
brew test stephenlclarke/tap/container-compose
```

Results:

- Stack consistency passed with all three Container refs aligned.
- Coverage/release tooling passed 156 release tests, 14 CI tests, 4 coverage
  tests, and its shell fixtures.
- Container's focused formula tests, 1,134-test unit run, and
  1,135-test instrumented coverage run passed.
- Stable formula tests passed with the service installed.
- A live installed-package Compose named-volume lifecycle passed and cleaned
  up completely.

## Compatibility and risks

This is a packaging-provenance update only. Container commit `5de53c9b` differs
from the `0.8.0` runtime commit only in its Homebrew formula test, regression,
and handoff documentation. No packaged executable source changed.

The direct tap correction preserves the stable and Current asset URLs,
versions, and checksums. The next Current package still rebuilds the matched
pair so its metadata and formula generation originate from the same final
source graph.

## PR template

### Type of change

- [x] Dependency provenance
- [x] Homebrew reliability
- [x] Documentation update
- [ ] Compose behavior
- [ ] Breaking change

### Motivation and context

Ensure every future generated Container formula inherits the deterministic
smoke that passed with an already-running service.

### Testing

- [x] SwiftPM resolution reproduced
- [x] Stack consistency passed
- [x] Release-tool regressions passed
- [x] Container full unit and unit-coverage gates passed
- [x] Stable Homebrew formula tests passed
- [x] Installed stable Compose lifecycle passed
- [ ] Exact-main CI, SonarQube, CodeQL, Current package, and VHS publication

Related issue handoff:
`docs/upstream/container-compose/ISSUE-homebrew-service-state-pin-20260723.md`.
