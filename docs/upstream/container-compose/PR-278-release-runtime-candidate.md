# Pull request: validate parity with uncontended release artifacts

## Summary

- Build the stable Container runtime candidate with the release Swift configuration and give its retained archive a release-specific identity.
- Build and execute the release Compose binary for the full Docker parity gate.
- Fail before isolated runtime validation when a production Container Homebrew or apiserver launch agent is loaded.
- Hold the host-wide runtime lock while temporarily stopping and later
  restoring cooperating Compose and devcontainer launch agents around a direct
  local release gate; a hosted gate preserves only its own runner.
- Atomically drain idle competing Actions runners and fail closed without
  mutation when GitHub reports an active or indeterminate job.
- Preserve the strict corresponding-fixture 10x timing guard without retries, normalization, or a waiver.

See the companion [issue handoff](ISSUE-278.md).

Tracking pull requests:

- [`stephenlclarke/container-compose#338`](https://github.com/stephenlclarke/container-compose/pull/338)
- [`stephenlclarke/container-compose#339`](https://github.com/stephenlclarke/container-compose/pull/339)

## Motivation and context

The stable helper previously invoked Container's Homebrew package target without overriding its debug default, while the full Compose parity target depended on the debug Compose build. The resulting binaries were not the artifacts intended for publication.

After both candidates were corrected to release builds, the focused bridge-start oracle still recorded 10.62x. A process and launchd audit found the installed `container-current` apiserver had crash-looped 9,592 times and relaunched approximately every ten seconds. Each failed start invoked Keychain authentication while the isolated release candidate was being measured. The harness changed only the candidate namespace, so its existing `system stop` could not stop or serialize that production agent.

The runner now rejects those loaded production agents before doing candidate work. It does not stop unrelated services, weaken isolation, retry parity fixtures, or silently switch dedicated workloads to shared-VM isolation.

The subsequent complete release gate stopped at 11.63x with the exact same
release artifacts. The executable preflight had not encoded the already
documented requirement to quiesce non-production Container-family workers: the
Compose release runner, devcontainer release runner, and Homebrew devcontainer
engine were all loaded. Pull request 339 makes that state transition explicit,
recoverable, and serialized with every other runtime user. Colima is
deliberately retained because it is the Docker reference, not a competing
Container-family worker.

## Code map

- `scripts/CONTAINER_STACK_RELEASE.sh` builds, names, fingerprints, and reuses a signed release Container archive.
- The same release helper records the loaded cooperating-worker set, unloads it
  only after acquiring the existing host-wide runtime lock, and restores
  exactly that set before releasing the lock on success, failure, or signal
  cleanup.
- For Actions runners, the helper checks exact repository registration state,
  suspends the idle listener process group, rechecks remote activity and local
  worker presence while no new assignment can start, then removes the launch
  agent. Every failure and EXIT path resumes a suspended listener.
- `Makefile` makes the full parity target build and inject the release Compose executable.
- `scripts/run-with-container-runtime.sh` inspects the two production launch-agent entry points and fails fast when either can compete with isolated validation.
- `Tools/ci/test_build_release_local_stack.py`, `Tools/release/test_container_stack_release.py`, and `Tools/ci/test_run_with_container_runtime.py` cover the release configuration, archive identity, Compose executable, and loaded-agent rejection.

## Focused validation

```console
python3 -m unittest \
  Tools.ci.test_run_with_container_runtime.RunWithContainerRuntimeTest.test_rejects_loaded_production_container_launch_agent \
  Tools.ci.test_run_with_container_runtime.RunWithContainerRuntimeTest.test_candidate_cli_leads_path_for_nested_commands \
  Tools.ci.test_run_with_container_runtime.RunWithContainerRuntimeTest.test_privacy_opt_out_skips_unused_local_user_root \
  Tools.ci.test_build_release_local_stack.BuildReleaseLocalStackTests.test_full_parity_uses_the_release_compose_binary \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_release_gate_includes_sibling_coverage_and_runtime_integration \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_local_release_gate_freezes_the_container_runtime_candidate \
  Tools.release.test_container_stack_release.ContainerStackReleasePolicyTests.test_runtime_candidate_staging_is_read_only_reusable_and_marker_cleaned
bash -n scripts/run-with-container-runtime.sh scripts/CONTAINER_STACK_RELEASE.sh
shellcheck scripts/run-with-container-runtime.sh scripts/CONTAINER_STACK_RELEASE.sh
git diff --check
```

The pull request 339 follow-up additionally passes twenty-two focused release-policy
tests covering lock/quiescence order, configurable restoration retries, direct
quiescence/restoration, hosted-runner preservation, exact runner activity,
atomic activity and process-snapshot rechecking while the listener is
suspended, fail-closed stop behavior, hardware-virtualization preflight, and
release-root isolation. Failed launchd inspection is distinct from proven
absence. Restoration requires a live service, a responsive devcontainer public
API socket, and an online exact Actions runner registration. A live but
definitively unready service receives one bounded restart only after the
configured grace period; a replacement that has not published its PID yet is
not restarted repeatedly. The listener process group must be observably stopped
before its second activity snapshots begin. Every external readiness probe and
recovery action is supervised by the remaining elapsed recovery deadline. That
original deadline and the already-issued startup/restart state remain attached
to a failed service across EXIT retries. Signal-safe cleanup retains
restoration authority through candidate cleanup and the complete worker
recovery window. The
existing independent-user regression proves a second runtime user cannot
acquire the same lock before its holder releases it. A live production-path
exercise acquired the runtime lock, atomically drained and unloaded all three
installed cooperating agents, proved none remained during the controlled
window, restored all three as healthy idle/online services, verified the
devcontainer `/_ping` endpoint, and left Docker 29.2.1 available through
Colima.

The exact signed release candidate reports Container `6a094cd6acb5`, Containerization `e5a92e86bf03`, and `build: release`. Its archive SHA-256 is `312eb81da6db336f0bbcef53c618b71bf599b97a503d5b1066e8ad213849a35f`.

With the competing production agents absent, three unchanged-artifact repetitions record:

| Operation | Docker Compose median | Container Compose median | Candidate/reference | Result |
| --- | ---: | ---: | ---: | --- |
| `network_mode: bridge` up | 0.133s | 1.293s | 9.69x | Pass |
| `network_mode: bridge` down | 10.076s | 5.718s | 0.57x | Pass |

Raw timing TSV, JUnit XML, the human matrix, and exact runtime fingerprints are retained in `.build/release-evidence/post-context-reuse-host-namespaces/`.

## Compatibility and remaining risk

- Ordinary Container and Compose builds retain their existing debug defaults; only stable packaging and the full stable parity target force release configuration.
- A loaded production agent now causes an immediate actionable failure instead of a contaminated benchmark or an unattended Keychain dialog.
- A direct stable release now temporarily unloads only known Compose and
  devcontainer workers with user-owned regular launch-agent plists. Missing,
  unsafe, or unresponsive state fails closed, and restoration is retried.
- A competing Actions runner is removed only after exact GitHub activity is
  idle, its listener group is suspended, and both GitHub activity and local
  worker presence are rechecked. Every visible process-group member must first
  report a stopped state. Active or indeterminate runners are resumed and left
  untouched.
- Quiescence accepts absence only from a successful launchd snapshot.
  Restoration authority is retained until every service has a live process and
  each Actions runner is online again. The devcontainer engine must also answer
  its public socket health endpoint. Recovery has a 60-second per-service
  elapsed deadline by default, bounds every external probe and recovery action
  by the remaining time, and restarts a live but definitively unready service
  at most once after a 10-observation grace period. An EXIT retry reuses the
  retained deadline and action state instead of granting a second recovery
  window or issuing another restart.
- Once recovery begins, follow-up termination signals cannot interrupt worker
  restoration or release the host lock prematurely. The same protection starts
  before candidate cleanup on the EXIT path.
- The worker window is inside the same host-wide runtime lock used by every
  cooperating validation path. Workers are restored before that lock is
  released, so a waiting release must quiesce the newly restored set itself.
- A hosted stable gate derives and preserves its own exact runner label so it
  can report the job result; other cooperating workers remain quiesced.
- The launch-agent check covers stable and current Homebrew service entry points plus the stock apiserver entry point. A non-launchd process that ignores the shared runtime lock remains outside this narrow guard.
- A read-only upgrade probe against this Mac's old default state correctly failed closed: that Keychain item was created by an ad-hoc development binary on 5 August 2026 and is ACL-bound to its obsolete code hash. A clean item created by the signed release candidate on 30 August carries the stable Developer ID designated requirement and team identifier instead.

  The contaminated default state is excluded from release evidence and must be preserved or explicitly recovered separately; it is not evidence that a clean signed 0.13 installation cannot upgrade.
- The passing result is close to the 10x diagnostic boundary. It clears the exact stable gate but does not close issue 278 or establish comparable dedicated-VM startup performance.
- The complete stable release gate, exact-head review, publication, release-only quality checks, and final DocC rebuild remain required after this focused correction is merged.
