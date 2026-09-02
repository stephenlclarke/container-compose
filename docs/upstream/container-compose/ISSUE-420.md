# Issue 420: pin release Xcode and run DocC after functional validation

## Problem

Stable release gate run [`33586058372`](https://github.com/stephenlclarke/container-compose/actions/runs/33586058372) selected the Command Line Tools developer directory. Source capture and functional work ran for more than three minutes before Containerization documentation failed because SwiftPM could not access `docc`.

The release graph also embedded documentation in the early Containerization and Container validation commands. That made a missing documentation tool a late failure and allowed DocC to run before the remaining functional release proof had completed.

Tracking issue: [`#420`](https://github.com/stephenlclarke/container-compose/issues/420).

## Required outcome

- Pin the dedicated stable-release runner to the full Xcode developer directory.
- Preserve that selection through the pipeline's clean environment.
- Resolve and authenticate DocC during preflight, before repository builds start.
- Run Containerization and Container documentation only after every functional validation receipt exists.
- Retain content-addressed recovery so unchanged successful stages are reused.

## Acceptance evidence

- Nextflow lint and the selected release-hosted pipeline plan pass.
- A selected Containerization and Container documentation preflight resolves full Xcode and DocC without executing a build.
- Focused release-policy tests, workflow parsing, licence checks, and `git diff --check` pass.
- Exact-head CI and review pass.
- The 0.13.1 stable gate resumes from retained candidate state and completes.

## Scope

This changes release orchestration only. Candidate source, product behavior, and published artifacts are unchanged.
