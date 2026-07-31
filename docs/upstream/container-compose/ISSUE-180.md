# [Request]: Restore the parity foundation validation gates

## Feature or enhancement request details

The reviewed parity-programme baseline at
`6a0a7e608632a7e4b1fd05f50f3f687370325e88` cannot use `make check` or
`make ci` as programme evidence because `make upstream-handoff-registry-check`
fails on two unregistered legacy documents:

```text
legacy handoff document is not registered as active: docs/upstream/container-compose/ISSUE-performance-matrix.md
legacy handoff document is not registered as active: docs/upstream/container-compose/PR-performance-matrix.md
```

Those documents describe the lifecycle performance-matrix implementation that
already shipped in published commit
`e4e93f43481bc5cfef803263507a9f68031d7f19`. They are no longer an active
proposal, but deleting them without a registry record would lose their durable
history.

Classify the pair as `archived`, retain immutable links to the published commit,
remove the duplicate active copies, regenerate the reader view, and prove both
the focused unit suite and the public registry check green. Keep this repair
separate from runtime feature implementation.

Mark Initial Workflow Enabler 12 complete in the programme cycle once those
gates pass so later slices do not continue treating the restored registry as a
pre-existing blocker.

The same reviewed base also has seven pre-existing runtime-validation failures:
four commands are now correctly documented as partially parity-compatible, but
their help metadata still presents them as fully supported; the command totals
therefore compare unlike classifications; and two grouped service attributes
are represented by narrower canonical code spans. A separate concurrent
service-discovery assertion also assumes an order that the production contract
does not promise. Reconcile the help metadata and assertions with the reviewed
documentation model so the unchanged runtime behaviour can pass the foundation
gate without hiding user-visible limitations.

## Compose compatibility impact

Documentation, contributor workflow, and CLI support metadata. This does not
alter Compose parsing, runtime behaviour, stack pins, or performance claims; it
restores the evidence gate required before parity work can rely on
repository-wide checks.

## Acceptance criteria

- [x] The performance-matrix issue and pull-request documents have one explicit
  registry classification.
- [x] Their immutable archive URLs resolve through the published implementation
  commit.
- [x] The retired active copies are removed.
- [x] The generated Markdown registry is fresh.
- [x] `make upstream-handoff-registry-check` passes.
- [x] The registry unit tests pass.
- [x] The programme status and Enabler 12 entry record the restored baseline.
- [x] Command help and STATUS agree that `attach`, `logs`, `run`, and `up` are
  partial, render their gap details, and derive matching totals from the help
  metadata.
- [x] Grouped service attributes retain explicit canonical documentation
  aliases instead of weakening the coverage assertion globally.
- [x] The concurrent service-discovery assertion compares membership rather
  than scheduler order.
- [x] Focused Swift tests and the pull-request runtime gate pass.
- [x] Local Sonar analysis includes the changed test inputs, and the exact-head
  SonarCloud GitHub check passes.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
- [x] I checked existing issue records before preparing this request.
