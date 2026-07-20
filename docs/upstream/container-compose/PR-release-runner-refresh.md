# Pull Request

## Summary

- Make the self-hosted Apple-silicon release-runner installer maintain an existing runner, not merely report that it exists.
- Verify GitHub's published SHA-256 before stopping the runner; retain its registration and launchd configuration across a binary refresh.
- Refuse a bad archive without touching the service and restart the service if a post-extraction version check fails.

## Type of Change

- [x] Release workflow reliability correction
- [x] Self-hosted runner maintenance and regression coverage
- [ ] Apple Container API change
- [ ] Apple Containerization API change

## Apple-Shaped Boundary

No forked Apple source changes are required. This retains the existing physical macOS runner required by Container guest validation while keeping the reliability logic in the Compose-owned bootstrap script. The refresh does not alter Container guest, networking, volume, or security behaviour.

## Commit Tracking

- `fix(release): refresh stale release runner safely`

## Code Map

- `scripts/install-scheduled-release-runner.sh`: obtains the latest macOS ARM64 asset and digest, compares the installed listener, downloads and verifies before stopping, updates in place, verifies the listener version, and restarts the registered service.
- `Tools/release/test_install_scheduled_release_runner.py`: exercises stale-to-current update, no-op current state, bad-digest service preservation, failed-version recovery, and help text.
- `BUILD.md`: describes rerunning the same bootstrap command as a safe runner-maintenance operation.

## Validation

```console
python3 -m unittest Tools.release.test_install_scheduled_release_runner
bash -n scripts/install-scheduled-release-runner.sh
./scripts/install-scheduled-release-runner.sh --help
./scripts/install-scheduled-release-runner.sh
```

## Compatibility and Risks

- The installer accepts only GitHub's latest checksummed macOS ARM64 runner archive.
- A matching installed version leaves the running service untouched.
- A digest failure occurs before `svc.sh stop`; extraction or version failure restarts the prior registered service rather than silently leaving the release runner offline.
- Runner registration and Git credentials are preserved in the existing private runner directory and are not copied into the repository, an Actions secret, or the archive.

## container-compose Checks

- [x] The change is macOS-only release-host maintenance and uses no Linux or Windows primitive.
- [x] Existing Apple runtime behaviour is unchanged.
- [x] The updater is tested for both its happy path and failure recovery.
- [x] Current help, BUILD documentation, code, tests, and handoff records describe the same behaviour.
