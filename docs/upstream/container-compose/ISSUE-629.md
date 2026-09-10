# Issue 629: Preserve immutable prerelease documentation authority

Issue [#629](https://github.com/stephenlclarke/container-compose/issues/629) tracks the failed documentation tail of the published 0.14.3 release.

## Failure

The released documentation manifest pins container-k8s tag `homebrew-main-17-21b4325d2d16` at immutable commit `21b4325d2d169aab4c4ff9090720f2f141e99860`. That snapshot is intentionally a published prerelease, but the documentation authority verifier incorrectly generalized the Compose stable-release rule and rejected every container-k8s prerelease.

## Contract

- Keep the Compose semantic release restricted to a published non-prerelease.
- Permit the separately pinned container-k8s documentation snapshot to be a published release or prerelease, but never a draft.
- Bind the exact container-k8s release ID, tag, commit, and prerelease state into the authority digest checked before and after Pages deployment.
- Preserve immutable documentation source checkouts and fail closed if any authority changes during deployment.

## Evidence

Documentation run [34491354958](https://github.com/stephenlclarke/container-compose/actions/runs/34491354958) rejected the exact pinned snapshot after stable package run [34489932954](https://github.com/stephenlclarke/container-compose/actions/runs/34489932954) published and verified the complete 0.14.3 artifact closure.
