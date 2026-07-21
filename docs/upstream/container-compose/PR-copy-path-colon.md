# Pull Request: consume the colon-safe copy runtime

## Summary

- Pin Compose to the generic Container copy parser correction.
- Keep the release stack manifest and resolved package graph aligned.
- Record why no Docker Compose v2 YAML parity fixture exists for this command.

## Type of Change

- [x] Runtime dependency update
- [ ] Compose syntax change
- [ ] Docker Compose v2 YAML parity fixture (not applicable: no `copy` model)
- [ ] Apple Containerization API change

## Apple-Shaped Boundary

The functional change is the generic Container parser correction documented in
[PR-copy-path-colon.md](../apple-container/PR-copy-path-colon.md). Compose
does not implement `container copy`; it consumes the immutable revision through
the existing dependency abstraction and adds no Docker-shaped fallback.

## Commit Tracking

- Required Container commit:
  `f03ae577d1c45e31ee6934cb020addb80334cf2d`
  `fix(copy): preserve colons in container paths`

## Code Map

- `Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json`:
  retain one exact Container revision across the release graph.
- No Compose source or `docker-compose.yml` is changed because Docker Compose
  v2 has no copy command to normalize, plan, or execute.

## Validation

```console
CONTAINER_STACK_REPO=/Users/sclarke/github/container \
  python3 Tools/ci/check-stack-consistency.py
python3 -m unittest Tools.ci.test_check_stack_consistency
```

The dependency checks must pass against the committed Container source
checkout. Docker Compose v2 parity is intentionally not asserted: adding an
unrelated Compose file would provide no valid compatibility signal for this
standalone runtime CLI operation.

## Compatibility and Risks

- Compose service behavior and Docker Compose file conversion are unchanged.
- The correction is macOS-supported and generic; Windows-only behavior is not
  included.
- A source-matched local Container integration attempt timed out while starting
  its apiserver before a guest was created; cleanup stopped the service. The
  committed live test remains the runtime acceptance gate before a release is
  cut.
