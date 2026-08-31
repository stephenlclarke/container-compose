# Issue 357: bound Current Demo engine readiness

## Problem

The unattended Current Demo workflow started the exact packaged runtime successfully, then immediately ran the full `container system status` table while the Container Engine was still registering. The status command stopped after `containers.running`, never emitted the VHS readiness marker, and run [`33372198965`](https://github.com/stephenlclarke/container-compose/actions/runs/33372198965) failed after the 180-second screen wait.

Pull request [`#358`](https://github.com/stephenlclarke/container-compose/pull/358) added bounded JSON readiness probes but retained a redundant full status-table process after those probes had already proved `engineStatus=running`. Exact-Current run [`33376637204`](https://github.com/stephenlclarke/container-compose/actions/runs/33376637204) reached that table, stopped after `paths.appRoot`, and exhausted the 300-second VHS screen deadline. The preserved exact package subsequently started in 1.1 seconds, created both provider and Docker sockets, and returned JSON and table status in 0.09 seconds, isolating the remaining defect to the recorder's duplicate cold-start status rendering rather than the packaged runtime.

Tracking issue: [`#357`](https://github.com/stephenlclarke/container-compose/issues/357).

## Required outcome

- Probe the packaged runtime's Engine status through one bounded JSON authority.
- Do not launch a second status process after the bounded probe has already established readiness.
- Keep the existing isolated runtime, exact package, exact guest-image, and fail-closed publication authorities unchanged.
- Emit a concise visible Engine-running result and the VHS readiness marker only after the Engine is running.
- Exit the terminal session immediately with a distinct failure marker when the bounded startup sequence fails.
- Cover the bounded readiness contract with focused release-policy tests.

## Acceptance evidence

- The generated tape retains at most two bounded system-start attempts.
- Engine readiness is polled through bounded JSON status probes without a redundant table-status process.
- The screen wait covers the bounded startup envelope and matches only a result emitted after readiness succeeds.
- The focused release-policy test, VHS tape validation, Actionlint, Markdown lint, and `git diff --check` pass.
- A fresh exact-Current demo completes after the fix reaches the mutable `current` release and before closeout.
