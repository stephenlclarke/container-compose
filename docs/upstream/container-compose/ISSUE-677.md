# Issue 677: recover a completed checkpoint after descendant cleanup

Unattended stable release run
[34862188599](https://github.com/stephenlclarke/container-compose/actions/runs/34862188599)
completed the exact 0.15.2 `sibling-stack` checkpoint successfully. All 309
concurrent tests and 100 serial live integration tests passed, combined
coverage export completed, and the durable checkpoint recorded status 0 after
5,182.011461 seconds. The nested process supervisor then found one Xcode
Python descendant still live after the configured 30-second drain, terminated
the owned session, and returned exit 125 as designed.

The completed checkpoint was safe to verify after bounded cleanup, but the
controller had no recovery-only path. Retrying the GitHub Actions run also
changed two execution destinations: the operation-scoped Developer ID
keychain filename and the GitHub handoff-output file. The inherited-environment
fingerprint treated those destinations as product inputs, so the retry received
a new digest and began repeating the 86-minute stage instead of reusing its
exact successful proof.

The release checkpoint controller needs an explicit opt-in recovery policy. On
exit 125 it may start one newly supervised, reuse-only worker only after the
supervisor positively observes that cleanup drained the complete session.
That worker must recompute the complete fingerprint, validate the success log
and every required output, and refuse to execute the stage if reuse is not
available. The general command supervisor and checkpoint controller must retain
their fail-closed defaults. Timeouts, failed stages, invalid evidence, changed
inputs, a second leaked process, an unavailable checkpoint, unknown process
inspection, or incomplete cleanup remain hard failures.

The two retry-scoped destination paths must not invalidate proof. The actual
Developer ID fingerprint remains a result-bearing input through
`CONTAINER_RUNTIME_CODESIGN_IDENTITY`; a changed signing identity must still
change the environment fingerprint. Successful bounded recovery must be
recorded in both the success and last-result records for auditability.

Related issue:
[#677](https://github.com/stephenlclarke/container-compose/issues/677).
