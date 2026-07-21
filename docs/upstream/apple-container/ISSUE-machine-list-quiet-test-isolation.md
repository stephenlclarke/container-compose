# Test gap: quiet machine-list integration assumes exclusive runtime ownership

## Summary

`TestCLIMachineRuntimeSerial.testListQuietMode` creates and boots one machine,
then invokes `machine ls -q`. The former assertion required the complete output
to equal that machine's ID. On a shared macOS runtime, a valid pre-existing
machine therefore produced a false test failure even though quiet output listed
the test machine correctly and contained no table header.

## Reproduction on macOS

1. Leave any valid machine in the runtime application root.
2. Run `TestCLIMachineRuntimeSerial/testListQuietMode`.
3. Before the correction, `machine ls -q` returns both IDs and the test fails
   because it expects a singleton list.

## Expected behavior

The test must verify its own machine is present and that quiet mode emits no
`NAME` table header. It must not delete or make assertions about machines it
did not create.

## Ownership and boundary

This is generic `apple/container` integration-test isolation on macOS. It
changes neither the machine runtime nor Compose behavior, and adds no Linux
guest or Windows path.

## Commit tracking

- `e36445bff4ff764d51e0349d9fa799906e953976` —
  `test(machine): isolate quiet machine listings`.

## Validation expectations

- Reproduce with a valid unrelated machine present, then confirm the target
  quiet-list test passes while that machine remains untouched.
- Run the complete coverage gate and preserve the source-matched integration
  evidence before proposing this test correction upstream.
