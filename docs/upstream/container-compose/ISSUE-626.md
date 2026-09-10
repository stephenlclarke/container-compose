# Issue 626: Preserve stable retry control authority after main advances

Issue [#626](https://github.com/stephenlclarke/container-compose/issues/626) tracks a Stable Release Gate failure exposed while recovering the unpublished 0.14.3 release.

## Failure

The gate accepts that a GitHub-verified unpublished semantic tag can remain the immutable package source after release automation changes on `main`. It then rejects that same tag unless it is also the head of a `release-X.Y` branch. The project does not use long-lived release branches, so the documented exact-version recovery path cannot reach the hosted release graph after a release-control fix advances `main`.

## Contract

- Keep the signed semantic tag, candidate CI, and stable init-image authority bound to the immutable package source.
- Use the exact current `main` revision as the independently pinned release-control authority for a latest-tag retry.
- Recheck both the current control revision and signed source tag before recording candidate-bound Stable Release Authority.
- Preserve the existing maintenance-branch path and reject stale semantic tags or candidates without successful SonarQube-backed CI.

## Evidence

Stable Release Gate run [34477380301](https://github.com/stephenlclarke/container-compose/actions/runs/34477380301) stopped in `Resolve Stable Candidate` after logging that 0.14.3 was an accepted verified unpublished retry, then rejected it because no `release-0.14` branch exists.
