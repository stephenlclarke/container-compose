# Branch Guide

This repository uses `main` as the active development branch. The free SonarCloud project only provides a useful branch signal for one branch, so active work, README badges, full CI, CodeQL, and SonarQube quality reporting all stay on `main`.

Frozen install branches are created from validated `main` commits when a release or snapshot should be made available through prebuilt GitHub release assets and the Homebrew tap.

## Branch Model

| Branch pattern | Purpose | CI profile | README badges |
| --- | --- | --- | --- |
| `main` | Active development and integration branch | Full CI, Quality, CodeQL, SonarQube | SonarCloud and security badges stay visible. |
| `release/*` | Frozen release lane for installable release builds | Reduced package and formula validation | SonarCloud badges are removed automatically. |
| `snapshot/*` | Frozen snapshot lane for installable debug builds | Reduced package and formula validation | SonarCloud badges are removed automatically. |
| `apple-container-compatible` | Upstream-only compatibility branch for accepted or released Apple runtime primitives | Targeted compatibility validation | Branch-specific. |

Do not use a long-lived `develop` branch for normal work. New changes should land on `main`, where the SonarCloud badges reflect the current branch state.

## Frozen Branch Automation

Pushing a `release/*` or `snapshot/*` branch starts the frozen branch workflow:

1. Prepare the branch by removing SonarCloud badge lines from `README.md`.
2. Commit that README change back to the frozen branch when needed.
3. On the follow-up workflow run for the prepared branch tip, build the prebuilt package.
4. Publish the package to a branch-specific `homebrew-*` GitHub release.
5. Update `stephenlclarke/homebrew-tap` so Homebrew installs the matching frozen asset.

`release/*` branches build release packages. `snapshot/*` branches build debug packages.

The tap update requires the `HOMEBREW_TAP_TOKEN` repository secret with permission to push to `stephenlclarke/homebrew-tap`.

Frozen branch packages include a plugin `build-info.json` file. `container compose version` reads that file and reports the lane, branch, commit, build type, `container` pin, and `containerization` pin used for the package. Use `container system version` beside it to confirm the actual running `container` runtime source and `containerization` ref.

## Local Branch Selection

For active development:

```sh
git -C ~/github/container-compose checkout main
git -C ~/github/container checkout main
```

For a frozen release or snapshot branch, check out the matching `container-compose` branch and the `container` fork revision pinned by `APPLE_CONTAINER_REF`:

```sh
git -C ~/github/container-compose checkout release/example
git -C ~/github/container fetch fork
git -C ~/github/container checkout "$(cat ~/github/container-compose/APPLE_CONTAINER_REF)"
```

`Package.swift` references the `container` checkout as a sibling path dependency at `../container`, so the checked-out `container` revision is part of the selected environment.

The current integration stack still pins [`stephenlclarke/containerization`](https://github.com/stephenlclarke/containerization) `integration/blkio-runtime` through `Package.swift` and `Package.resolved` until the block I/O runtime API from [`apple/containerization#739`](https://github.com/apple/containerization/pull/739) is accepted upstream.

## Archive Branches

| Branch | Status | Notes |
| --- | --- | --- |
| `compose-v2-preview` | Legacy preview archive | Preserves older preview harness and handoff state. Do not treat this as the current compatibility target. |

The former `develop`, `regression`, `logs-integration`, `logs-integration-chris`, `full-compose-preview`, and `full-compose-runtime` branches are not current development targets. Historical handoff notes may still mention those names when they identify where a slice originally came from, but new work should not target them.

## Upstreaming Rule

Fork-backed runtime changes should still be split into small Apple-facing branches before opening pull requests against [`apple/container`](https://github.com/apple/container). Keep one runtime capability per PR where practical, with focused tests and no Compose-specific policy in the runtime branch.

Compose-specific behavior stays in this repository, including service fan-out, replica selection, prefixes, colors, selected-service ordering, Docker Compose CLI parsing, and Docker Compose output formatting.
