# Pull request: recover Current VHS runtime startup

## Summary

- Wait for the self-hosted runner's complete Container launchd namespace to
  remain absent before unpacking the next exact demo runtime.
- Fail closed if launchd cannot be queried or retained services do not settle.
- Type one bounded retry of the exact runtime start in the visible VHS
  terminal command.
- Reduce the first live-output wait from 900 to 180 seconds.
- Preserve the direct typed-command/live-output recording contract.

Resolves
[`stephenlclarke/container-compose#160`](https://github.com/stephenlclarke/container-compose/issues/160).

## Intended review delta

Apply signed implementation commit
[`f0e1fbbd12e2af63b5cb643aa00287c8f1820d33`](https://github.com/stephenlclarke/container-compose/commit/f0e1fbbd12e2af63b5cb643aa00287c8f1820d33)
and connector follow-up
[`18652f78bf523504bd2e76cb7f58f5c1ad79b658`](https://github.com/stephenlclarke/container-compose/commit/18652f78bf523504bd2e76cb7f58f5c1ad79b658),
plus their documentation commits from `fix/current-vhs-start-recovery`. See
the companion [issue handoff](ISSUE-current-vhs-start-recovery.md).

## Code map

- `Tools/release/wait-for-container-system-stop.sh` polls `launchctl list` and
  requires three consecutive observations with no `com.apple.container.*`
  service.
- `.github/workflows/prebuilt-binaries.yml` runs that guard after stopping the
  retained runtime and before deleting or unpacking the exact demo root.
- `docs/container-compose-demo.tape` visibly types the exact start command and
  at most one identical retry after five seconds, then requires live running
  status.
- `Tools/release/test_wait_for_container_system_stop.py` covers quiescence and
  failure boundaries with an injected launchctl executable.
- `Tools/release/record-vhs-live-demo.sh` reapplies stable quiescence after a
  transport-only recorder reset stops a partially booted service.
- `Tools/release/test_record_vhs_live_demo.py` proves that waiter invocation
  precedes a fresh recorder session and fails closed if teardown never settles.
- `Tools/release/test_container_stack_release.py` locks workflow ordering,
  bounded waiting, and typed-command source shape.

## Validation

```console
bash -n Tools/release/wait-for-container-system-stop.sh
python3 -m unittest \
  Tools.release.test_wait_for_container_system_stop \
  Tools.release.test_record_vhs_live_demo \
  Tools.release.test_container_stack_release
python3 -m unittest discover Tools/release
vhs validate docs/container-compose-demo.tape
markdownlint \
  docs/upstream/container-compose/ISSUE-current-vhs-start-recovery.md \
  docs/upstream/container-compose/PR-current-vhs-start-recovery.md
git diff --check
```

Results:

- 73 release and recorder tests pass.
- Five new tests cover stable absence, reappearance, persistent services,
  launchctl failure, and impossible wait bounds.
- A connector P2 identified that transport-only retries bypassed the new
  pre-recording waiter. The direct fix and its new fail-closed regression test
  pass all 11 focused recorder/quiescence tests.
- The complete release suite passes 174 tests; `make lint` also passes all
  coverage-tool, CI-policy, shell-syntax, Markdown, and Go-format checks.
- The actual stopped launchd namespace on the designated MBP passed the
  default three-observation stability window.
- VHS source validation passes.
- The tape retains 16 `Type` and 16 `Enter` instructions, with zero Replay and
  zero Marker instructions.

Hosted review, exact-main gates, and Current publication evidence are added
before this recovery closes.

## Compatibility and risk

- The quiescence helper observes only the existing release cleanup; it does
  not stop services itself.
- A recorder never begins while matching launchd services are still visible.
- A transport-only VHS reset cannot start another recorder session until the
  service it stopped passes the same stability window.
- The typed retry uses the same exact package, app root, install root, kernel
  installation, and timeout options.
- Both start attempts must fail before the existing live status assertion can
  block publication.
- No prerecorded output, transcript renderer, Replay, or Marker is introduced.

## Checklist

- [x] Signed Conventional implementation commit
- [x] Signed Conventional documentation commit
- [x] Focused release and recorder tests
- [x] Complete release test suite
- [x] VHS validation
- [ ] Pull-request checks and connector review
- [ ] Exact-main Current publication and live GIF
