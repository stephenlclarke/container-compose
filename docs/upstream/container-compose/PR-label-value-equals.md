# Pull Request

## Summary

- Pin Compose to the generic Container label parser correction.
- Keep the release stack manifest and checked-in lockfile aligned.
- Extend Docker Compose v2 OCI annotation parity to an equals-valued label.

## Type of Change

- [x] Runtime dependency update
- [x] Docker Compose v2 configuration and dry-run parity coverage
- [ ] Compose syntax change
- [ ] Apple Containerization API change

## Apple-Shaped Boundary

The fork change is a generic Container parser correction documented in
[PR-label-value-equals.md](../apple-container/PR-label-value-equals.md).
Compose only consumes that immutable revision and tests its own label/annotation
translation boundary. It adds no Docker-shaped behavior below Compose.

## Commit Tracking

- `b48711cb344434a3a2b2cbf301953cd5a40d2f4c`
  `fix(labels): preserve equals-valued labels`
- Required Container commit:
  `47c13a8ad0bf001fb569a17e73e2e3b8d4e45dff`
  `fix(labels): preserve equals in values`

## Code Map

- `Package.swift`, `Package.resolved`, and `Tools/release/stack-refs.json`:
  retain one exact Container revision across the release graph.
- `Tools/parity/fixtures/oci-annotations/compose.yaml`: provides a label value
  with multiple `=` characters.
- `Tools/parity/check-compose-oci-annotations.sh`: verifies Docker Compose v2
  config, Compose config, and Compose dry-run output retain it exactly while
  keeping OCI annotations separate.

## Validation

```console
CONTAINER_STACK_REPO=/Users/sclarke/github/container \
  python3 Tools/ci/check-stack-consistency.py
python3 -m unittest Tools.ci.test_check_stack_consistency
make docker-compose-oci-annotations-parity
```

All commands above passed against Docker Compose v5.3.1 and the committed
source checkout.

## Compatibility and Risks

- Existing simple label values and annotations are unchanged.
- The corrected runtime parser is macOS-supported and generic; Windows-only
  behavior is not included.
- The isolated local Container integration runner timed out before guest
  startup; its committed regression test must pass on a healthy macOS
  Virtualization/XPC runner before a release is cut.
