# Pull Request: isolate candidate public Docker socket service ownership

## Summary

- Derive and validate a candidate-only Container service namespace from the
  marker-protected runtime root and UID.
- Route candidate start, status, socket verification, and stop through that
  namespace instead of a legacy global service set.
- Retain a focused Docker CLI lifecycle certificate proving candidate cleanup
  did not interrupt the user-owned `devcontainer-engine`.

See the companion [issue handoff](ISSUE-runtime-isolated-public-socket.md).

## Motivation and context

App-root isolation alone did not isolate Container's launchd/Mach service
ownership. Consequently, a candidate test could remove an unrelated runtime
when `container system stop` ran during cleanup. The change preserves the
default stock namespace for ordinary callers while making the Compose candidate
path choose and verify a deterministic, root-specific namespace.

## Code map

- `scripts/run-with-container-runtime.sh`
  - derives and validates the namespace and expected socket, rejects legacy
    global cleanup, and invokes only candidate-scoped lifecycle commands.
- `Tools/ci/test_run_with_container_runtime.py`
  - covers namespace derivation, invalid inputs, socket preflight, candidate
    cleanup, and default-namespace guardrails.
- `Makefile`
  - forwards the candidate runtime configuration without changing ordinary
    default-namespace workflows.

The paired lower-runtime service routing lives in Container commit
`c740a8f6a79ce176d03a941f49cdfe7350625a71` and has its own Apple-shaped
handoff.

## Validation

- [x] Focused runner test suite: 14 tests, 99% branch coverage.
- [x] Candidate source/dependency/binary/guest/root fingerprint recorded in
  `/private/tmp/ctr-isopub4.Id3j22`.
- [x] Candidate Docker CLI response: `29.7.1|29.2.1|linux`.
- [x] Candidate socket and all candidate launchd services absent after its
  trap-owned stop; the pre-existing `devcontainer-engine` stayed running and
  responsive.
- [x] Bash syntax, ShellCheck, Python compilation, and diff checks passed.

## Compatibility and risk

Default callers retain stock Container service names and the shared runtime
lock. Only an explicit, validated `CONTAINER_SERVICE_NAMESPACE` selects the
new socket and service labels. This local verification path is not a claim of
generic multi-runtime support, logging-driver parity, or release performance.

## Publication status

No pull request has been opened. This is a local, unsubmitted handoff for
`stephenlclarke/container-compose`; do not publish it or the paired Container
change until all programme work is complete and explicit authorisation is
given.
