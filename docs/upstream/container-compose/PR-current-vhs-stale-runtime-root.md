# Pull request: reset retained Current VHS runtime state

## Summary

- Stop a retained Current-demo CLI before replacing its isolated package.
- Use the installed Container CLI as a fallback stop authority.
- Delete the retained package and app root before exact artifact extraction.
- Add a focused ordering regression test.
- Keep startup, status, Compose commands, and results inside the typed/live VHS
  recording.

Resolves
[`ISSUE-current-vhs-stale-runtime-root.md`](ISSUE-current-vhs-stale-runtime-root.md).

## Type of change

- [x] Self-hosted Current release reliability
- [x] VHS live-runtime correctness
- [x] Focused release-policy test
- [ ] Runtime API
- [ ] Windows behavior

## Root cause

Current workflow `30068134568` attempt 1 reached the first tape command while a
different source runtime owned the global launchd service. The typed
`system start` rejected the requested app root, leaving the recorder at its
required `Wait+Screen /status +running/` assertion. This was correct
fail-closed behavior, but the packaging step had no pre-extraction cleanup for
state retained by the self-hosted runner.

## Commit and code map

Signed implementation:

- `930984761daf09d3341e1b3dc5982f23c5a57349`
  `fix(release): reset current demo runtime root`

Files:

- `.github/workflows/prebuilt-binaries.yml`: stop the retained or installed
  runtime, then clear the demo root before artifact extraction.
- `Tools/release/test_container_stack_release.py`: assert stop/delete/extract
  ordering while retaining the typed/live recording policy.

## Validation

```console
python3 -m unittest \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_current_build_records_and_publishes_the_matched_vhs_demo
make check
```

- Focused workflow-policy test: passed.
- Repository check after implementation and all eight handoffs: passed,
  including 1,119 Swift tests, 91.42% Swift coverage, 90.06% Go coverage,
  release-policy tests, and stack consistency.
- Exact-main Current workflow and rendered GIF: pending until the signed branch
  is merged.
- Tape instructions: 16 `Type`, 16 `Enter`, 14 `Wait`, 27 `Sleep`, zero
  `Replay`, and zero `Marker`.

## Compatibility and risk

- The change is confined to a dedicated self-hosted release workspace.
- Cleanup happens before exact archives are extracted, so no published asset
  can contain retained package or app-root data.
- The final trap still stops the exact newly extracted runtime.
- The workflow does not pre-render command output; the published GIF remains a
  real typed terminal session.
