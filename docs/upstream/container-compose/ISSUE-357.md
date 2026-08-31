# Issue 357: bound Current Demo engine readiness

## Problem

The unattended Current Demo workflow started the exact packaged runtime successfully, then immediately ran the full `container system status` table while the Container Engine was still registering. The status command stopped after `containers.running`, never emitted the VHS readiness marker, and run [`33372198965`](https://github.com/stephenlclarke/container-compose/actions/runs/33372198965) failed after the 180-second screen wait.

Tracking issue: [`#357`](https://github.com/stephenlclarke/container-compose/issues/357).

## Required outcome

- Probe the packaged runtime's Engine status before rendering the visible status table.
- Bound every readiness probe and the visible status command so an unattended runner cannot wait indefinitely.
- Keep the existing isolated runtime, exact package, exact guest-image, and fail-closed publication authorities unchanged.
- Emit the VHS readiness marker only after the Engine is running and the visible status table completes.
- Exit the terminal session immediately with a distinct failure marker when the bounded startup sequence fails.
- Cover the bounded readiness contract with focused release-policy tests.

## Acceptance evidence

- The generated tape retains at most two bounded system-start attempts.
- Engine readiness is polled through bounded JSON status probes before the visible status table.
- The visible status command has its own deadline and the screen wait covers the bounded startup envelope.
- The focused release-policy test, VHS tape validation, Actionlint, Markdown lint, and `git diff --check` pass.
- A fresh exact-Current demo completes after the fix reaches the mutable `current` release and before closeout.
