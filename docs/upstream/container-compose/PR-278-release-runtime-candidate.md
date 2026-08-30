# Pull request: validate parity with uncontended release artifacts

## Summary

- Build the stable Container runtime candidate with the release Swift configuration and give its retained archive a release-specific identity.
- Build and execute the release Compose binary for the full Docker parity gate.
- Fail before isolated runtime validation when a production Container Homebrew or apiserver launch agent is loaded.
- Preserve the strict corresponding-fixture 10x timing guard without retries, normalization, or a waiver.

See the companion [issue handoff](ISSUE-278.md).

Tracking pull request: [`stephenlclarke/container-compose#338`](https://github.com/stephenlclarke/container-compose/pull/338).

## Motivation and context

The stable helper previously invoked Container's Homebrew package target without overriding its debug default, while the full Compose parity target depended on the debug Compose build. The resulting binaries were not the artifacts intended for publication.

After both candidates were corrected to release builds, the focused bridge-start oracle still recorded 10.62x. A process and launchd audit found the installed `container-current` apiserver had crash-looped 9,592 times and relaunched approximately every ten seconds. Each failed start invoked Keychain authentication while the isolated release candidate was being measured. The harness changed only the candidate namespace, so its existing `system stop` could not stop or serialize that production agent.

The runner now rejects those loaded production agents before doing candidate work. It does not stop unrelated services, weaken isolation, retry parity fixtures, or silently switch dedicated workloads to shared-VM isolation.

## Code map

- `scripts/CONTAINER_STACK_RELEASE.sh` builds, names, fingerprints, and reuses a signed release Container archive.
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

The exact signed release candidate reports Container `b19e8205fc91`, Containerization `e5a92e86bf03`, and `build: release`. Its archive SHA-256 is `a2a7eb7e487689a24a25948fd433b166f3b6e9ee16a8ce103833d530a86a80c1`.

With the competing production agents absent, three unchanged-artifact repetitions record:

| Operation | Docker Compose median | Container Compose median | Candidate/reference | Result |
| --- | ---: | ---: | ---: | --- |
| `network_mode: bridge` up | 0.137s | 1.299s | 9.46x | Pass |
| `network_mode: bridge` down | 10.146s | 5.803s | 0.57x | Pass |

Raw timing TSV, JUnit XML, the human matrix, and exact runtime fingerprints are retained in `.build/release-evidence/release-candidate-host-namespaces-quiet/`.

## Compatibility and remaining risk

- Ordinary Container and Compose builds retain their existing debug defaults; only stable packaging and the full stable parity target force release configuration.
- A loaded production agent now causes an immediate actionable failure instead of a contaminated benchmark or an unattended Keychain dialog.
- The launch-agent check covers stable and current Homebrew service entry points plus the stock apiserver entry point. A non-launchd process that ignores the shared runtime lock remains outside this narrow guard.
- A read-only upgrade probe against this Mac's old default state correctly failed closed: that Keychain item was created by an ad-hoc development binary on 5 August 2026 and is ACL-bound to its obsolete code hash. A clean item created by the signed release candidate on 30 August carries the stable Developer ID designated requirement and team identifier instead.

  The contaminated default state is excluded from release evidence and must be preserved or explicitly recovered separately; it is not evidence that a clean signed 0.13 installation cannot upgrade.
- The passing result is close to the 10x diagnostic boundary. It clears the exact stable gate but does not close issue 278 or establish comparable dedicated-VM startup performance.
- The complete stable release gate, exact-head review, publication, release-only quality checks, and final DocC rebuild remain required after this focused correction is merged.
