# Support `compose up` Exit Control

## Summary

`container compose up --exit-code-from SERVICE`, `--abort-on-container-exit`, and `--abort-on-container-failure` should be accepted for attached `up` runs and should stop the project when the selected exit condition is reached.

The plugin already supports detached starts, health waits, timestamped log follow, and positive attach log selection. The remaining Compose-side gap is exit-control mode: services need to start in a controllable background state, the selected containers need to be waited through the runtime lifecycle API, and the project needs to be torn down before returning the selected or failing service exit status.

## Acceptance Criteria

- `container compose help up` shows `--exit-code-from`, `--abort-on-container-exit`, and `--abort-on-container-failure` as supported.
- Exit-control mode starts the selected service graph detached so the plugin can keep process control.
- `up --exit-code-from SERVICE` waits for the selected service container and returns that exit code from the CLI.
- `up --abort-on-container-exit` waits for the first started service container to exit, tears the project down, and returns that exit status.
- `up --abort-on-container-failure` waits until a started service container fails, or until all selected containers exit successfully, then tears the project down and returns the failure or success status.
- `--exit-code-from SERVICE` validates that the selected service is part of the started graph before runtime side effects.
- Exit-control options reject incompatible `--detach`, `--wait`, `--no-start`, and `--watch` combinations.
- Dry-run output shows the detached starts, lifecycle wait, and down plan without requiring a live container runtime.
- Focused unit tests cover selected exit status, failure abort status, dry-run planning, validation, parser behavior, and CLI help support.
- A compose.yml runtime smoke proves a real `up --exit-code-from SERVICE` returns the selected service status through the CLI.

## Notes

This is a Compose-side change. It reuses the existing direct lifecycle wait, stop, and delete APIs already used by other commands and does not require new apple/container APIs.
