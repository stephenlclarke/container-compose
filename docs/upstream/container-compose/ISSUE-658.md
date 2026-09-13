# Issue 658: Prevent unattended release runner self-deadlock

Issue [#658](https://github.com/stephenlclarke/container-compose/issues/658) tracks two recovery failures exposed while publishing 0.15.1.

## Failure

The scheduled stable-release controller waited synchronously for the Stable Release Gate while it occupied the only `container-compose-release` runner required by that downstream gate. The release could not advance without an operator cancelling the waiter.

After the gate was dispatched directly, package recovery found a complete retained asset manifest whose release-authority bundle belonged to an earlier receipt. The package workflow selected the current successful gate receipt, rejected the stale retained bundle, and stopped before publication. Because retained stable names are immutable, simply downloading the new authority would later conflict with the old manifest records.

## Contract

- Release the sole macOS runner before waiting for downstream runner work.
- Carry exact version, source, control commit, and run IDs across a hosted continuation.
- Reuse or dispatch each downstream run idempotently and verify the immutable release and paired Homebrew formulae.
- Reuse a retained authority only when it matches the selected successful gate receipt.
- Before replacing stale authority records, prove that no GitHub draft or published release exists.
- Invalidate only the authority archive and checksum records while preserving their content-addressed objects and every other retained asset.
- Keep ordinary local release commands synchronous and preserve all existing signed-tag, exact-source, parity, signing, notarization, and publication gates.

## Evidence

Scheduled release run [34754959188](https://github.com/stephenlclarke/container-compose/actions/runs/34754959188) exposed the runner self-deadlock. Direct Stable Release Gate run [34755243802](https://github.com/stephenlclarke/container-compose/actions/runs/34755243802) passed, after which package run [34756751937](https://github.com/stephenlclarke/container-compose/actions/runs/34756751937) failed closed because the retained authority receipt digest did not match the current check.
