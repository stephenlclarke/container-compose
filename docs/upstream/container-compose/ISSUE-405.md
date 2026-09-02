# Issue 405: stage release VM source mounts on the system volume

## Problem

The checkpointed 0.13.1 stable-release gate completed its earlier sibling stages, then remained indefinitely in `created/starting` while macOS Virtualization opened the Containerization checkout through `VZSharedDirectory`. The checkout lived on `/Volumes/SSD`; a live process sample showed the launchd-managed VM helper blocked at `open(2)` on that removable-volume bind mount instead of returning a test result.

After the Containerization source was localized, the next exact gate reached Container coverage integration and exposed the same boundary in its sibling checkout. Unified macOS evidence showed the freshly built `container-apiserver` remained inside `xpcproxy`: TCC attributed the ad-hoc coverage binary to `/Volumes/SSD`, denied its unattended background access, and the CLI eventually reported an XPC ping timeout.

Tracking issue: [`#405`](https://github.com/stephenlclarke/container-compose/issues/405).

## Required outcome

- Stage the exact tracked Containerization checkout under the marker-protected release runtime parent on the internal system volume before VM-backed validation.
- Prove the staged Git tree equals the selected source tree and has neither an inherited object-directory override, object-store alternate, incomplete object closure, nor removable-volume remote.
- Preserve the installed release-policy tool and already-provisioned kernel without copying prior build outputs.
- Use the local checkout for both the Containerization init source and sibling validation input.
- Stage the exact Container sibling checkout beside Containerization so its freshly built launchd/XPC services also execute from the internal system volume.
- Publish one stable, exact-target system-volume alias so historical release sources do not fingerprint a random path; current sources additionally fingerprint the relocated checkout by its Git tree, Hawkeye, and kernel content.
- Remove the checkout through the existing runtime-parent cleanup lifecycle after success, failure, or interruption.
- Preserve exact-input checkpoints so a corrected retry does not repeat completed validation stages.

## Acceptance evidence

- Focused functional regression supplies an inherited object-directory override, creates an exact self-contained local clone, preserves its executable Hawkeye tool and kernel, removes its source remote, deletes the source repository, and then rechecks the staged object closure and tree hash.
- Focused failure-injection regression invokes staging through the production conditional boundary and proves a tool-copy failure cannot be reported as success.
- Focused fingerprint regression proves two relocated copies of the same checkout reuse one identity while a changed kernel invalidates it.
- Focused alias regression proves the stable historical-source path is exactly targeted, removes a stale release alias safely, and is removed after the attempt.
- Focused policy regression proves both VM consumers receive the staged path after the runtime parent is created.
- Focused Container regression proves the second exact checkout needs no kernel supplement, retains only Hawkeye outside its tracked tree, and receives a distinct stable alias with exact-target cleanup.
- Bash syntax, ShellCheck, Markdown lint, `git diff --check`, and exact-head review pass.
- The checkpointed 0.13.1 gate resumes through Containerization and Container coverage integration without a removable-volume approval prompt or an `xpcproxy` startup stall.

## Scope

This changes only local stable-release validation staging. It does not change Compose functionality, weaken exact-tree or signing authority, grant privacy permissions, copy prior build outputs, or move benchmark inputs onto removable storage.
