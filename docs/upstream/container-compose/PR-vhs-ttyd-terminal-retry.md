# Pull request: recover transient VHS terminal resets without replaying output

<!-- markdownlint-disable MD013 -->

## Summary

- Extract the release recording retry policy into a small, testable helper.
- Retry only a `ttyd` reset that happens before a terminal session begins.
- Keep all live command, output, and expected-output failures fail-closed.
- Preserve the Current GIF as a VHS-typed terminal session, not a replay.

## Type of Change

- [x] Bug fix
- [ ] New feature
- [ ] Breaking change
- [x] Documentation update

## Motivation and Context

The self-hosted Apple-silicon Current release runner can encounter a transient
VHS terminal-server reset while starting its browser connection. The failed run
never reached a Container or Compose command, yet blocked publishing the
required Current prerelease artifact.

The repair intentionally does not weaken the demo requirement. The same VHS
tape still types every command, waits for its live output, and cannot publish a
GIF when any typed command or output assertion fails.

## Commit Tracking

- Code and tests:
  `057fb7a21ee6928553ed5385443308bb695662cc`
  (`fix(release): retry transient vhs terminal resets`).
- Reproduction run:
  [29885990747](https://github.com/stephenlclarke/container-compose/actions/runs/29885990747).

## Implementation Details

- `Tools/release/record-vhs-live-demo.sh` owns the bounded retry policy and is
  injectable through `VHS_BIN` for unit tests.
- A nonzero VHS execution is retried only if its captured log contains
  `could not open ttyd`; all other failures stop immediately.
- The helper deletes any partial output and stops the isolated Container system
  between eligible retries.
- A successful VHS process must still produce a nonempty GIF before the release
  workflow can stage it.
- The workflow validates the source tape first, then calls the helper; it has
  no transcript, replay, or marker fallback path.

## Docker Compose Compatibility Notes

No Docker Compose command semantics change. The published demonstration
continues to execute the portable monitoring-stack lifecycle against the
matched packaged macOS runtime, preserving the Compose-v2 parity boundary.

## Testing

- [x] Tested locally on the MBP release host
- [x] Added unit coverage for every retry outcome
- [x] Validated the typed-command VHS tape
- [x] Validated GitHub Actions workflow syntax

```sh
bash -n Tools/release/record-vhs-live-demo.sh
python3 -m unittest discover Tools/release
vhs validate docs/container-compose-demo.tape
actionlint .github/workflows/prebuilt-binaries.yml
git diff --check
```

Results: 143 release tests passed. A real local helper invocation completed
with VHS 0.11.0 and emitted a 1600×720 GIF. Its behavior tests cover one
successful retry after a simulated `ttyd` reset, two retry cleanups before
bounded exhaustion, a live-command failure that is never retried, a missing
asset, and invalid configuration.

## Review Checklist

- [x] The direct VHS tape still types commands and waits for live output.
- [x] Only the documented pre-command transport failure is retried.
- [x] Other recorder and demo failures remain fail-closed.
- [x] No Apple runtime or Compose compatibility logic changed.
- [x] Commits are signed and use Conventional Commit subjects.
