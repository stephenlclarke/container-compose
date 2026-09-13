# Issue 660: Complete retained authority recovery before staging

Issue [#660](https://github.com/stephenlclarke/container-compose/issues/660) tracks a second unpublished stable-release recovery boundary exposed by the 0.15.1 package retry.

## Failure

Package run [34758093897](https://github.com/stephenlclarke/container-compose/actions/runs/34758093897) accepted the current gate receipt, replaced the stale authority records, built and signed both archives, and created attestations. Staging then found that the retained manifest still lacked the current authority pair. Its later complete-set retain correctly rejected the newly timestamp-signed package bytes because the same immutable names already referred to earlier candidate bytes.

No GitHub release or Homebrew mutation occurred.

## Contract

- Retain a newly verified current authority archive and checksum immediately.
- Preserve every unrelated retained object and manifest record.
- Let staging rematerialize a now-complete retained set before comparing newly timestamp-signed products.
- Preserve the no-existing-release proof, immutable-name protection, exact-source checks, signing, attestations, and publication transaction.
- Cover ordering and both authority assets in the workflow contract tests.

## Expected recovery

On the next retry, the current authority pair completes the provisional retained manifest. Staging then restores the earlier signed package, runtime, highlights, and quality snapshot together with that authority. The package workflow can publish exactly those immutable bytes without weakening conflict detection.
