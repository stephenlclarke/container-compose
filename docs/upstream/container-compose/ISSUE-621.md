# Issue 621: Recover stale retained release runtime namespaces

Issue [#621](https://github.com/stephenlclarke/container-compose/issues/621)
tracks a release-gate cleanup gap exposed while resuming the retained 0.14.3
transaction.

## Failure

The release gate correctly detected seven processes from an older isolated
release-runtime namespace under the exact protected Container candidate. Its
graceful stop addressed only the current namespace, so the gate failed closed
without a bounded recovery path for the retained namespace.

## Contract

- Keep the current namespace's graceful `container system stop` as the first
  cleanup action.
- While the global runtime lock is held, identify older release namespaces from
  one launchd and process snapshot.
- Boot out a stale service only when its live PID, user ID, and executable path
  prove that it belongs to the same validated candidate root.
- Continue to reject current-namespace survivors, ambiguous services, orphaned
  candidate processes, launchd inspection failures, and process inspection
  failures.

## Evidence

The focused lifecycle suite covers successful retained-namespace recovery,
current-namespace fail-closed behavior, and refusal to touch a similarly named
service without candidate ownership.
