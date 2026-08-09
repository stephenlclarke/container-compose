# Issue 197: scaled log parity truncates non-hex hostnames

## Steps to reproduce

Run the signal/log reliability fixture against a candidate whose service hostnames include letters outside hexadecimal and hyphens, such as `cc-sl-a1b2-c3d4`.

The harness used `[0-9a-f]+` to capture hostnames. Docker's random hexadecimal identifiers passed, but candidate identifiers were truncated to `cc`, causing a false scale-parity failure and hiding duplicate/truncation defects.

## Problem description

The scale assertion must validate the full non-whitespace identifier emitted by the workload, independent of whether an implementation uses Docker-style hexadecimal IDs or another valid hostname shape.

The fix must:

1. Capture complete non-whitespace identifiers.
2. Require exactly the expected replica count and uniqueness.
3. Keep the assertion sourceable for focused unit tests without executing the live harness.
4. Cover Docker hexadecimal, candidate hyphenated, and duplicate failure cases.

## Environment

- **OS**: macOS 26.5.2, arm64 Mac17,9
- **Docker**: Engine 29.2.1 / Compose 5.3.1
- **container-compose**: signed local `main` through `c7a50e28438ca0c5bd5a668d3b8e87db25c4a176`

## Tracking

- GitHub issue: [stephenlclarke/container-compose#197](https://github.com/stephenlclarke/container-compose/issues/197)
- This is a project harness defect, not an Apple runtime bug.
